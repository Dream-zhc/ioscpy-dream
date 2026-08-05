#import "StreamClient.h"
#import "Capture.h"
#import "Encoder.h"
#import "Protocol.h"
#import "InputInjector.h"
#import "KeyboardSuppression.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

// JPEG fallback quality. Frame rate, dimensions, H.264 bitrate, and keyframe
// interval are negotiated per stream through IOSPYStreamConfig.
static const CGFloat kQuality = 0.72;

static double streamNowMs(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

// clipboard sync bookkeeping (must hash byte-identically to the host)
static uint64_t gLastSyncedHash = 0;
static BOOL gHaveHash = NO;
static NSInteger gLastSeenChangeCount = -1;
static NSInteger gSuppressUntilChangeCount = -1;

static uint64_t clipHash(NSString *t) {
    NSData *d = [t dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint64_t h = 1469598103934665603ULL;
    const uint8_t *b = (const uint8_t *)d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        h ^= b[i];
        h *= 1099511628211ULL;
    }
    return h;
}

@interface IOSPYStreamClient ()
- (void)startClipboardObserver;
- (void)checkClipboard;
- (void)applyRemoteClipboard:(NSString *)text paste:(BOOL)paste;
- (void)sendClipboardChanged:(NSString *)text;
- (void)resetStreamStats;
- (void)emitStatsIfNeeded;
@end

@implementation IOSPYStreamClient {
    int _fd;
    dispatch_queue_t _captureQueue;
    dispatch_queue_t _sendQueue;
    dispatch_source_t _timer;
    dispatch_queue_t _clipQueue;   // ALL UIPasteboard access happens here, off-main
    dispatch_source_t _clipTimer;
    IOSPYH264Encoder *_encoder;    // created lazily on the capture queue
    NSLock *_socketWriteLock;      // prevents frame/control write interleaving
    uint8_t _codec;                // 0 = MJPEG, 1 = H.264 (host's request)
    BOOL _needKeyframe;            // force an H.264 keyframe on the next frame
    NSUInteger _h264InFlight;
    NSUInteger _sendBacklog;
    uint64_t _encoderEpoch;
    IOSPYStreamConfig _config;

    double _streamStartMs;
    double _lastStatsMs;
    uint64_t _captureTicks;
    uint64_t _capturedFrames;
    uint64_t _encodedFrames;
    uint64_t _sentFrames;
    uint64_t _droppedFrames;
    double _captureMsTotal;
    double _encodeMsTotal;
    double _sendMsTotal;
}

+ (instancetype)shared {
    static IOSPYStreamClient *client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = [[IOSPYStreamClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _config = IOSPYParseStreamConfig(nil);
        _codec = _config.codec;
        _captureQueue = dispatch_queue_create("com.ioscpy.capture", DISPATCH_QUEUE_SERIAL);
        _sendQueue = dispatch_queue_create("com.ioscpy.send", DISPATCH_QUEUE_SERIAL);
        _clipQueue = dispatch_queue_create("com.ioscpy.clip", DISPATCH_QUEUE_SERIAL);
        _socketWriteLock = [[NSLock alloc] init];
        [self startClipboardObserver];
    }
    return self;
}

// Watch the device pasteboard and push changes to the Mac. ALL UIPasteboard
// access runs on _clipQueue (a dispatch-source timer, no main runloop) so a
// Handoff or Universal Clipboard stall on .string can never wedge SpringBoard.
- (void)startClipboardObserver {
    _clipTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _clipQueue);
    dispatch_source_set_timer(_clipTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_clipTimer, ^{
        [self checkClipboard];
    });
    dispatch_resume(_clipTimer);
}

// Runs on _clipQueue (off the main thread).
- (void)checkClipboard {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger cc = pb.changeCount;
    if (cc <= gSuppressUntilChangeCount) {
        gLastSeenChangeCount = cc; // our own write, swallow it
        return;
    }
    if (cc == gLastSeenChangeCount) {
        return;
    }
    gLastSeenChangeCount = cc;
    if (!pb.hasStrings) {
        return;
    }
    NSString *t = pb.string; // may block on Handoff, fine since we're off-main
    if (t.length == 0) {
        return;
    }
    uint64_t h = clipHash(t);
    if (gHaveHash && h == gLastSyncedHash) {
        return; // echo of what the host just pushed to us
    }
    gLastSyncedHash = h;
    gHaveHash = YES;
    [self sendClipboardChanged:t];
}

- (void)sendClipboardChanged:(NSString *)text {
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) {
        return;
    }
    uint8_t flags = 0;
    NSMutableData *body = [NSMutableData dataWithCapacity:1 + utf8.length];
    [body appendBytes:&flags length:1];
    [body appendData:utf8];
    // NEVER write the socket on the main thread. A stalled write would wedge
    // SpringBoard and trip the watchdog. Serialize with capture writes to _fd.
    dispatch_async(_sendQueue, ^{
        int fd = self->_fd;
        if (fd >= 0) {
            [self->_socketWriteLock lock];
            IOSPYWriteFrame(fd, IOSPYMsgClipboardChanged, IOSPY_CHANNEL_CONTROL, 0, body);
            [self->_socketWriteLock unlock];
        }
    });
}

- (void)applyRemoteClipboard:(NSString *)text paste:(BOOL)paste {
    dispatch_async(_clipQueue, ^{
        uint64_t h = clipHash(text);
        if (!(gHaveHash && h == gLastSyncedHash)) {
            gLastSyncedHash = h;
            gHaveHash = YES;
            UIPasteboard *pb = [UIPasteboard generalPasteboard];
            gSuppressUntilChangeCount = pb.changeCount + 1; // arm before write
            pb.string = text;
        }
        if (paste) {
            IOSPYKeyAction(12); // Cmd+V; IOSPYKeyAction hops to the main queue itself
        }
    });
}

- (void)start {
    [NSThread detachNewThreadSelector:@selector(connectLoop) toTarget:self withObject:nil];
}

- (void)connectLoop {
    while (1) {
        int fd = [self connectToDaemon];
        if (fd < 0) {
            sleep(1);
            continue;
        }
        _fd = fd;
        NSLog(@"[ioscpyhook] attached to daemon frame channel");
        [self readCommandsFrom:fd]; // blocks until the channel drops

        // Link to the daemon dropped (restart or crash). Never leave the device's
        // keyboard hidden behind a dead session.
        dispatch_async(dispatch_get_main_queue(), ^{ IOSPYSetKeyboardSuppressed(NO); });
        dispatch_async(_captureQueue, ^{ [self stopCapture]; });
        _fd = -1;
        close(fd);
        sleep(1);
    }
}

- (int)connectToDaemon {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(IOSPY_FRAME_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    int yes = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    return fd;
}

- (void)readCommandsFrom:(int)fd {
    IOSPYFrameHeader header;
    BOOL connected = YES;
    while (connected) {
      @autoreleasepool {
        NSData *payload = nil;
        if (!IOSPYReadFrame(fd, &header, &payload)) {
            connected = NO;
            continue;
        }
        if (header.type == IOSPYMsgStartStream) {
            IOSPYStreamConfig config = IOSPYParseStreamConfig(payload);
            dispatch_async(_captureQueue, ^{
                [self stopCapture];
                self->_config = config;
                self->_codec = config.codec;
                self->_needKeyframe = YES;
                [self resetStreamStats];
                [self startCapture];
            });
        } else if (header.type == IOSPYMsgStopStream) {
            dispatch_async(_captureQueue, ^{ [self stopCapture]; });
        } else if (header.type == IOSPYMsgRequestKeyframe) {
            dispatch_async(_captureQueue, ^{ self->_needKeyframe = YES; });
        } else if (header.type == IOSPYMsgInputTouch && payload.length >= 10) {
            const uint8_t *b = (const uint8_t *)payload.bytes;
            uint8_t phase = b[0];
            uint8_t fingerID = b[1];
            uint32_t xb, yb;
            memcpy(&xb, b + 2, 4);
            memcpy(&yb, b + 6, 4);
            xb = ntohl(xb);
            yb = ntohl(yb);
            float x, y;
            memcpy(&x, &xb, 4);
            memcpy(&y, &yb, 4);
            dispatch_async(dispatch_get_main_queue(), ^{
                IOSPYInjectTouch((IOSPYTouchPhase)phase, fingerID, x, y);
            });
        } else if (header.type == IOSPYMsgSystemAction && payload.length >= 2) {
            const uint8_t *b = (const uint8_t *)payload.bytes;
            uint16_t action;
            memcpy(&action, b, 2);
            action = ntohs(action);
            dispatch_async(dispatch_get_main_queue(), ^{ IOSPYSystemAction(action); });
        } else if (header.type == IOSPYMsgInputText && payload.length > 0) {
            NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
            if (text) {
                IOSPYTypeText(text);
            }
        } else if (header.type == IOSPYMsgInputKey && payload.length >= 1) {
            uint8_t code = ((const uint8_t *)payload.bytes)[0];
            IOSPYKeyAction(code);
        } else if (header.type == IOSPYMsgClipboardSet && payload.length >= 1) {
            // [flags:u8][utf8 text]; flags bit0 = paste after set.
            uint8_t flags = ((const uint8_t *)payload.bytes)[0];
            NSData *body = [payload subdataWithRange:NSMakeRange(1, payload.length - 1)];
            NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            if (text) {
                [self applyRemoteClipboard:text paste:(flags & 0x01) != 0];
            }
        } else if (header.type == IOSPYMsgKeyboardMode && payload.length >= 1) {
            // Hide/restore the on-screen keyboard. On the main thread (UIKit reads
            // the flag there) and only touched from main, so no races.
            BOOL on = ((const uint8_t *)payload.bytes)[0] != 0;
            dispatch_async(dispatch_get_main_queue(), ^{ IOSPYSetKeyboardSuppressed(on); });
        }
      }
    }
}

// everything below runs on _captureQueue

- (void)startCapture {
    if (_timer) {
        return;
    }
    if (!IOSPYCaptureAvailable()) {
        NSLog(@"[ioscpyhook] no capture backend available");
        return;
    }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
    uint16_t fps = MAX(_config.target_fps, 1);
    uint64_t interval = NSEC_PER_SEC / fps;
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, interval, interval / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf captureAndSend]; });
    dispatch_resume(_timer);
    NSLog(@"[ioscpyhook] capture started codec=%u fps=%u max=%u bitrate=%u mode=%u",
          _config.codec, fps, _config.max_dimension, _config.bitrate_bps,
          _config.latency_mode);
}

- (void)stopCapture {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
        NSLog(@"[ioscpyhook] capture stopped");
    }
    // Release the encoder's hardware session while idle; it lazily rebuilds.
    _encoderEpoch++;
    [_encoder invalidate];
    _h264InFlight = 0;
    _sendBacklog = 0;
}

- (void)resetStreamStats {
    _streamStartMs = streamNowMs();
    _lastStatsMs = _streamStartMs;
    _captureTicks = 0;
    _capturedFrames = 0;
    _encodedFrames = 0;
    _sentFrames = 0;
    _droppedFrames = 0;
    _captureMsTotal = 0;
    _encodeMsTotal = 0;
    _sendMsTotal = 0;
}

- (void)emitStatsIfNeeded {
    double now = streamNowMs();
    if (_fd < 0 || now - _lastStatsMs < 1000.0) {
        return;
    }
    NSDictionary *stats = @{
        @"uptime_ms": @((uint64_t)MAX(now - _streamStartMs, 0)),
        @"requested_fps": @(_config.target_fps),
        @"max_dimension": @(_config.max_dimension),
        @"bitrate_bps": @(_config.bitrate_bps),
        @"capture_ticks": @(_captureTicks),
        @"captured_frames": @(_capturedFrames),
        @"encoded_frames": @(_encodedFrames),
        @"sent_frames": @(_sentFrames),
        @"dropped_frames": @(_droppedFrames),
        @"capture_ms_avg": @(_capturedFrames ? _captureMsTotal / _capturedFrames : 0),
        @"encode_ms_avg": @(_encodedFrames ? _encodeMsTotal / _encodedFrames : 0),
        @"send_ms_avg": @(_sentFrames ? _sendMsTotal / _sentFrames : 0),
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:stats options:0 error:nil];
    if (body) {
        int fd = _fd;
        dispatch_async(_sendQueue, ^{
            if (fd >= 0 && fd == self->_fd) {
                [self->_socketWriteLock lock];
                IOSPYTryWriteFrame(fd, IOSPYMsgStats, IOSPY_CHANNEL_CONTROL, 0, body);
                [self->_socketWriteLock unlock];
            }
        });
    }
    _lastStatsMs = now;
    _captureTicks = 0;
    _capturedFrames = 0;
    _encodedFrames = 0;
    _sentFrames = 0;
    _droppedFrames = 0;
    _captureMsTotal = 0;
    _encodeMsTotal = 0;
    _sendMsTotal = 0;
}

- (void)captureAndSend {
    int fd = _fd;
    if (fd < 0) {
        return;
    }
    _captureTicks++;
    BOOL handled = NO;
    if (_codec == IOSPY_VIDEO_CODEC_H264) {
        if ([self captureAndSendH264:fd]) {
            handled = YES;
        } else {
            // H.264 isn't usable on this device/OS, so drop to MJPEG for the rest
            // of the session and keep the screen alive.
            [_encoder invalidate];
            _encoder = nil;
            _codec = IOSPY_VIDEO_CODEC_MJPEG;
            NSLog(@"[ioscpyhook] H.264 unavailable; using MJPEG");
        }
    }
    if (!handled) {
        [self captureAndSendJPEG:fd];
    }
    [self emitStatsIfNeeded];
}

// Current capture orientation packed into the VIDEO_FRAME flag bits, so the host
// can rotate the (always-portrait) framebuffer upright.
static uint32_t orientationFlags(void) {
    int o = IOSPYCurrentOrientation();
    return (uint32_t)(((o - 1) & 0x3) << IOSPY_VIDEO_ORIENT_SHIFT);
}

// Build and send a VIDEO_FRAME: 16-byte header (width, height, flags, data
// length, all big-endian) then the encoded bytes.
static NSData *makeVideoFrame(int width, int height, uint32_t flags, NSData *data) {
    NSMutableData *body = [NSMutableData dataWithCapacity:16 + data.length];
    uint32_t w = htonl((uint32_t)width);
    uint32_t h = htonl((uint32_t)height);
    uint32_t fl = htonl(flags);
    uint32_t len = htonl((uint32_t)data.length);
    [body appendBytes:&w length:4];
    [body appendBytes:&h length:4];
    [body appendBytes:&fl length:4];
    [body appendBytes:&len length:4];
    [body appendData:data];
    return body;
}

- (void)captureAndSendJPEG:(int)fd {
    int width = 0, height = 0;
    double captureMs = 0, encodeMs = 0;
    NSData *jpeg = IOSPYCaptureScreenJPEG(_config.max_dimension, kQuality, &width, &height,
                                          &captureMs, &encodeMs);
    if (!jpeg) {
        _droppedFrames++;
        return;
    }
    _capturedFrames++;
    _encodedFrames++;
    _captureMsTotal += captureMs;
    _encodeMsTotal += encodeMs;

    double sendStart = streamNowMs();
    [_socketWriteLock lock];
    BOOL sent = IOSPYWriteFrame(fd, IOSPYMsgVideoFrame, IOSPY_CHANNEL_VIDEO, 0,
                                makeVideoFrame(width, height, orientationFlags(), jpeg));
    [_socketWriteLock unlock];
    _sendMsTotal += streamNowMs() - sendStart;
    if (sent) {
        _sentFrames++;
    } else {
        _droppedFrames++;
    }
}

- (BOOL)captureAndSendH264:(int)fd {
    if (!IOSPYH264Available()) {
        return NO;
    }
    // Bound hardware work. A timer tick that arrives while two frames are still
    // encoding is stale by definition, so drop it instead of building latency.
    if (_h264InFlight >= 2) {
        _droppedFrames++;
        return YES;
    }
    if (!_encoder) {
        _encoder = [[IOSPYH264Encoder alloc] init];
    }
    int width = 0, height = 0;
    double captureStart = streamNowMs();
    IOSurfaceRef surface = IOSPYCaptureScreenSurface(_config.max_dimension, &width, &height);
    double captureMs = streamNowMs() - captureStart;
    if (!surface || width < 2 || height < 2) {
        _droppedFrames++;
        return NO;
    }
    _capturedFrames++;
    _captureMsTotal += captureMs;
    int fps = MAX(_config.target_fps, 1);
    BOOL forceKeyframe = _needKeyframe;
    uint64_t epoch = _encoderEpoch;
    double encodeStart = streamNowMs();
    _h264InFlight++;
    BOOL submitted = [_encoder submitSurface:surface
                                       width:width
                                      height:height
                                         fps:fps
                                     bitrate:_config.bitrate_bps
                            keyframeInterval:MAX(_config.keyframe_interval_frames, 1)
                               forceKeyframe:forceKeyframe
                                  completion:^(NSData *avcc, BOOL isKey, BOOL hardError) {
        double encodeMs = streamNowMs() - encodeStart;
        dispatch_async(self->_captureQueue, ^{
            if (epoch != self->_encoderEpoch) {
                return;
            }
            if (self->_h264InFlight > 0) {
                self->_h264InFlight--;
            }
            if (hardError) {
                self->_droppedFrames++;
                self->_codec = IOSPY_VIDEO_CODEC_MJPEG;
                self->_needKeyframe = YES;
                NSLog(@"[ioscpyhook] asynchronous H.264 encode failed; using MJPEG");
                return;
            }
            if (avcc.length == 0) {
                self->_droppedFrames++;
                if (forceKeyframe) {
                    self->_needKeyframe = YES;
                }
                return;
            }

            self->_encodedFrames++;
            self->_encodeMsTotal += encodeMs;
            if (isKey) {
                self->_needKeyframe = NO;
            }

            // Keep the socket queue short. If two encoded frames are already
            // waiting, discard this one and force a new keyframe so the decoder
            // can recover without replaying stale inter-frames.
            if (self->_sendBacklog >= 2) {
                self->_droppedFrames++;
                self->_needKeyframe = YES;
                return;
            }
            self->_sendBacklog++;
            uint32_t flags = IOSPY_VIDEO_FLAG_H264 | orientationFlags();
            if (isKey) {
                flags |= IOSPY_VIDEO_FLAG_KEYFRAME | IOSPY_VIDEO_FLAG_CONFIG;
            }
            NSData *frame = makeVideoFrame(width, height, flags, avcc);
            dispatch_async(self->_sendQueue, ^{
                double sendStart = streamNowMs();
                [self->_socketWriteLock lock];
                BOOL sent = fd >= 0 && fd == self->_fd &&
                    IOSPYWriteFrame(fd, IOSPYMsgVideoFrame, IOSPY_CHANNEL_VIDEO, 0, frame);
                [self->_socketWriteLock unlock];
                double sendMs = streamNowMs() - sendStart;
                dispatch_async(self->_captureQueue, ^{
                    if (epoch != self->_encoderEpoch) {
                        return;
                    }
                    if (self->_sendBacklog > 0) {
                        self->_sendBacklog--;
                    }
                    self->_sendMsTotal += sendMs;
                    if (sent) {
                        self->_sentFrames++;
                    } else {
                        self->_droppedFrames++;
                        self->_needKeyframe = YES;
                    }
                });
            });
        });
    }];
    if (!submitted) {
        if (_h264InFlight > 0) {
            _h264InFlight--;
        }
        _droppedFrames++;
        return NO; // hard failure, fall back to MJPEG
    }
    return YES;
}

@end
