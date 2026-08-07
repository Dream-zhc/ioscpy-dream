#import "FrameIngest.h"
#import "FrameStore.h"
#import "Protocol.h"

#import <sys/socket.h>
#import <sys/uio.h>
#import <netinet/in.h>
#import <netinet/ip.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const uint32_t kIOSPYLANVideoMagic = 0x49554450u; // "IUDP"
static const uint8_t kIOSPYLANVideoVersion = 1;
static const uint8_t kIOSPYLANVideoParityFlag = 0x01;
// Standard IPv4 LAN MTU is 1500. 1400 data + 32 app + 28 UDP/IP = 1460,
// avoiding IP fragmentation while keeping packet rate lower at 120 FPS.
static const size_t kIOSPYLANVideoFragmentPayload = 1400;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint8_t version;
    uint8_t flags;
    uint16_t headerSize;
    uint64_t token;
    uint32_t frameSequence;
    uint32_t frameLength;
    uint16_t fragmentIndex;
    uint16_t fragmentCount;
    uint16_t payloadLength;
    uint16_t reserved;
} IOSPYLANVideoHeader;

static_assert(sizeof(IOSPYLANVideoHeader) == 32, "LAN video header must remain 32 bytes");

@implementation IOSPYFrameIngest {
    uint16_t _port;
    int _listenFd;
    int _tweakFd;       // -1 when no tweak is connected
    NSLock *_writeLock; // guards _tweakFd and writes to it
    int _hostFd;        // the control server's host socket, -1 when none
    NSLock *_hostLock;  // the control server's per-connection write lock
    BOOL _videoReliable; // YES while an inter-frame H.264/HEVC stream is active
    int _udpFd;
    struct sockaddr_in _udpPeer;
    uint64_t _udpToken;
    uint32_t _udpFrameSequence;
    NSLock *_udpLock;
    CFAbsoluteTime _lastUDPKeyframeRequestTime;
}

+ (instancetype)shared {
    static IOSPYFrameIngest *ingest = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ingest = [[IOSPYFrameIngest alloc] init];
    });
    return ingest;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFd = -1;
        _tweakFd = -1;
        _writeLock = [[NSLock alloc] init];
        _hostFd = -1;
        _udpFd = -1;
        _udpLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)setLANVideoPeerAddress:(uint32_t)addressNetworkOrder
                           port:(uint16_t)portHostOrder
                          token:(uint64_t)token {
    [_udpLock lock];
    if (_udpFd >= 0) {
        close(_udpFd);
        _udpFd = -1;
    }
    memset(&_udpPeer, 0, sizeof(_udpPeer));
    _udpToken = 0;
    _udpFrameSequence = 0;
    if (portHostOrder > 0 && token != 0) {
        int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd >= 0) {
            int flags = fcntl(fd, F_GETFL, 0);
            if (flags >= 0) {
                fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            }
            int sndbuf = 8 * 1024 * 1024;
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
#if defined(SO_NET_SERVICE_TYPE) && defined(NET_SERVICE_TYPE_VI)
            int serviceType = NET_SERVICE_TYPE_VI;
            setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, sizeof(serviceType));
#endif
            int tos = IPTOS_LOWDELAY;
            setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
            _udpPeer.sin_family = AF_INET;
            _udpPeer.sin_addr.s_addr = addressNetworkOrder;
            _udpPeer.sin_port = htons(portHostOrder);
            _udpToken = token;
            _udpFd = fd;
            NSLog(@"[ioscpyd] LAN video UDP bound to %@:%u",
                  [NSString stringWithUTF8String:inet_ntoa(_udpPeer.sin_addr)],
                  portHostOrder);
        }
    }
    [_udpLock unlock];
}

- (BOOL)hasLANVideoPeer {
    [_udpLock lock];
    BOOL active = _udpFd >= 0 && _udpToken != 0;
    [_udpLock unlock];
    return active;
}

- (BOOL)sendLANVideoFrame:(NSData *)frame {
    if (frame.length == 0 || frame.length > UINT32_MAX) {
        return NO;
    }
    [_udpLock lock];
    if (_udpFd < 0 || _udpToken == 0) {
        [_udpLock unlock];
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)frame.bytes;
    size_t frameLength = frame.length;
    size_t fragmentCountSize =
        (frameLength + kIOSPYLANVideoFragmentPayload - 1) / kIOSPYLANVideoFragmentPayload;
    if (fragmentCountSize == 0 || fragmentCountSize > UINT16_MAX) {
        [_udpLock unlock];
        return NO;
    }
    uint16_t fragmentCount = (uint16_t)fragmentCountSize;
    uint32_t sequence = ++_udpFrameSequence;
    uint8_t parity[kIOSPYLANVideoFragmentPayload] = {};
    int localSendFailures = 0;

    for (uint16_t index = 0; index < fragmentCount; index++) {
        size_t offset = (size_t)index * kIOSPYLANVideoFragmentPayload;
        size_t length = MIN(kIOSPYLANVideoFragmentPayload, frameLength - offset);
        for (size_t i = 0; i < length; i++) {
            parity[i] ^= bytes[offset + i];
        }

        IOSPYLANVideoHeader header = {};
        header.magic = htonl(kIOSPYLANVideoMagic);
        header.version = kIOSPYLANVideoVersion;
        header.flags = 0;
        header.headerSize = htons((uint16_t)sizeof(header));
        header.token = CFSwapInt64HostToBig(_udpToken);
        header.frameSequence = htonl(sequence);
        header.frameLength = htonl((uint32_t)frameLength);
        header.fragmentIndex = htons(index);
        header.fragmentCount = htons(fragmentCount);
        header.payloadLength = htons((uint16_t)length);

        struct iovec iov[2] = {
            {&header, sizeof(header)},
            {(void *)(bytes + offset), length},
        };
        struct msghdr message = {};
        message.msg_name = &_udpPeer;
        message.msg_namelen = sizeof(_udpPeer);
        message.msg_iov = iov;
        message.msg_iovlen = 2;
        ssize_t sent = sendmsg(_udpFd, &message, MSG_DONTWAIT);
        if (sent < 0) {
            localSendFailures++;
        }
    }

    // One parity packet repairs any single missing data fragment in this frame.
    // This avoids an IDR storm from tiny Wi-Fi loss without introducing a jitter
    // buffer or retransmission delay.
    IOSPYLANVideoHeader parityHeader = {};
    parityHeader.magic = htonl(kIOSPYLANVideoMagic);
    parityHeader.version = kIOSPYLANVideoVersion;
    parityHeader.flags = kIOSPYLANVideoParityFlag;
    parityHeader.headerSize = htons((uint16_t)sizeof(parityHeader));
    parityHeader.token = CFSwapInt64HostToBig(_udpToken);
    parityHeader.frameSequence = htonl(sequence);
    parityHeader.frameLength = htonl((uint32_t)frameLength);
    parityHeader.fragmentIndex = htons(fragmentCount);
    parityHeader.fragmentCount = htons(fragmentCount);
    parityHeader.payloadLength = htons((uint16_t)sizeof(parity));
    struct iovec parityIov[2] = {
        {&parityHeader, sizeof(parityHeader)},
        {parity, sizeof(parity)},
    };
    struct msghdr parityMessage = {};
    parityMessage.msg_name = &_udpPeer;
    parityMessage.msg_namelen = sizeof(_udpPeer);
    parityMessage.msg_iov = parityIov;
    parityMessage.msg_iovlen = 2;
    if (sendmsg(_udpFd, &parityMessage, MSG_DONTWAIT) < 0) {
        localSendFailures++;
    }

    [_udpLock unlock];
    // A single failed data datagram is still repairable if parity was sent. Two
    // or more local failures make this frame unrecoverable.
    return localSendFailures <= 1;
}

- (void)setHostFd:(int)fd writeLock:(NSLock *)lock {
    @synchronized(self) {
        _hostFd = fd;
        _hostLock = lock;
    }
}

- (void)setVideoReliable:(BOOL)reliable {
    @synchronized(self) {
        _videoReliable = reliable;
    }
}

- (BOOL)startOnPort:(uint16_t)port {
    _port = port;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 2) != 0) {
        close(fd);
        return NO;
    }
    _listenFd = fd;
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    NSLog(@"[ioscpyd] frame channel listening on 127.0.0.1:%u", port);
    return YES;
}

- (void)acceptLoop {
    while (1) {
        int client = accept(_listenFd, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            usleep(100 * 1000);
            continue;
        }
        int yes = 1;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

        [_writeLock lock];
        if (_tweakFd >= 0) {
            close(_tweakFd);
        }
        _tweakFd = client;
        [_writeLock unlock];

        NSLog(@"[ioscpyd] tweak attached to frame channel");
        [self readFramesFrom:client];

        [_writeLock lock];
        if (_tweakFd == client) {
            _tweakFd = -1;
        }
        [_writeLock unlock];
        close(client);
        NSLog(@"[ioscpyd] tweak detached from frame channel");
    }
}

- (void)readFramesFrom:(int)fd {
    IOSPYFrameHeader header;
    while (1) {
        // Drain the per-frame payload each iteration so this hot read loop
        // doesn't pile up memory and get the daemon jetsam-killed.
        @autoreleasepool {
            NSData *payload = nil;
            if (!IOSPYReadFrame(fd, &header, &payload)) {
                break;
            }
            if (header.type == IOSPYMsgVideoFrame && payload.length > 0) {
                if ([self hasLANVideoPeer]) {
                    // LAN media is intentionally unreliable/latest-first. Never
                    // fall back to the control TCP stream after a UDP send miss:
                    // doing so would reintroduce head-of-line stalls exactly when
                    // Wi-Fi is under pressure. The Mac requests a fresh IDR when
                    // it detects an unrecoverable sequence gap.
                    if (![self sendLANVideoFrame:payload]) {
                        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                        if (now - _lastUDPKeyframeRequestTime >= 0.5) {
                            _lastUDPKeyframeRequestTime = now;
                            [self sendToTweak:IOSPYMsgRequestKeyframe];
                        }
                    }
                    continue;
                }
                BOOL reliable;
                @synchronized(self) {
                    reliable = _videoReliable;
                }
                if (reliable) {
                    // H.264/HEVC: send every frame to the host in order. A blocking
                    // write backpressures the tweak's encoder instead of dropping
                    // a frame, which would corrupt the inter-frame stream.
                    //
                    // This holds the shared host write lock for the whole send, so
                    // a slow host can briefly delay a PONG. In practice H.264 frames
                    // are tiny (a few KB) and fit the socket buffer, so the write
                    // returns right away. Only a host that has truly stopped reading
                    // blocks here, and that case should just drop and reconnect. A
                    // separate video socket would remove the coupling, but that's
                    // for later.
                    int hostFd;
                    NSLock *hostLock;
                    @synchronized(self) {
                        hostFd = _hostFd;
                        hostLock = _hostLock;
                    }
                    if (hostFd >= 0 && hostLock) {
                        [hostLock lock];
                        int rc = IOSPYTryWriteFrame(hostFd, IOSPYMsgVideoFrame,
                                                    IOSPY_CHANNEL_VIDEO, 0, payload);
                        [hostLock unlock];
                        if (rc == 0) {
                            // Preserve control responsiveness under Wi-Fi/host
                            // backpressure. Dropping an inter-frame requires a
                            // fresh keyframe before useful decoding can resume.
                            [self sendToTweak:IOSPYMsgRequestKeyframe];
                        } else if (rc < 0) {
                            break;
                        }
                    }
                } else {
                    // MJPEG: keep only the latest frame, the pump drops stale ones.
                    [[IOSPYFrameStore shared] setPayload:payload];
                }
            } else if (header.type == IOSPYMsgClipboardChanged ||
                       header.type == IOSPYMsgStats ||
                       header.type == IOSPYMsgAudioFrame) {
                // Relay tweak->host control events and periodic telemetry on the
                // host socket, serialized with the video pump's writes.
                int hostFd;
                NSLock *hostLock;
                @synchronized(self) {
                    hostFd = _hostFd;
                    hostLock = _hostLock;
                }
                if (hostFd >= 0 && hostLock) {
                    [hostLock lock];
                    // Non-blocking: clipboard and telemetry are best-effort and
                    // must never stall the tweak's capture path.
                    uint64_t channel = header.type == IOSPYMsgAudioFrame
                        ? IOSPY_CHANNEL_AUDIO : IOSPY_CHANNEL_CONTROL;
                    IOSPYTryWriteFrame(hostFd, (IOSPYMessageType)header.type,
                                       channel, 0, payload);
                    [hostLock unlock];
                }
            }
        }
    }
}

- (BOOL)tweakConnected {
    [_writeLock lock];
    BOOL connected = _tweakFd >= 0;
    [_writeLock unlock];
    return connected;
}

- (void)tellTweakStartPayload:(NSData *)payload {
    [_writeLock lock];
    if (_tweakFd >= 0) {
        IOSPYWriteFrame(_tweakFd, IOSPYMsgStartStream, IOSPY_CHANNEL_CONTROL, 0,
                        payload ?: [NSData data]);
    }
    [_writeLock unlock];
}

- (void)tellTweakStop {
    [self sendToTweak:IOSPYMsgStopStream];
}

- (void)sendToTweak:(IOSPYMessageType)type {
    [_writeLock lock];
    if (_tweakFd >= 0) {
        IOSPYWriteFrame(_tweakFd, type, IOSPY_CHANNEL_CONTROL, 0, nil);
    }
    [_writeLock unlock];
}

- (void)forwardToTweak:(uint16_t)type payload:(NSData *)payload {
    [_writeLock lock];
    if (_tweakFd >= 0) {
        IOSPYWriteFrame(_tweakFd, (IOSPYMessageType)type, IOSPY_CHANNEL_CONTROL, 0, payload);
    }
    [_writeLock unlock];
}

@end
