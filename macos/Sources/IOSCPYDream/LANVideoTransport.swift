import Darwin
import Foundation

/// LAN video datagram format. It deliberately stays independent from the
/// control TCP framing so packet loss can only discard a video frame, never
/// stall input behind TCP retransmission (head-of-line blocking).
private enum LANVideoWire {
    static let magic: UInt32 = 0x4955_4450 // "IUDP"
    static let version: UInt8 = 1
    static let headerSize = 32
    // IPv4 LAN MTU is normally 1500 bytes. 1400 + 32-byte app header +
    // UDP/IPv4 headers = 1460, avoiding IP fragmentation while reducing packet
    // rate versus a conservative Internet/QUIC-sized 1200-byte payload.
    static let maxFragmentPayload = 1400
    static let parityFlag: UInt8 = 0x01
}

private final class LANFrameAssembly {
    let frameLength: Int
    let fragmentCount: Int
    let createdAtNanos: UInt64
    var fragments: [Data?]
    var parity: Data?
    var receivedCount = 0

    init(frameLength: Int, fragmentCount: Int, createdAtNanos: UInt64) {
        self.frameLength = frameLength
        self.fragmentCount = fragmentCount
        self.createdAtNanos = createdAtNanos
        fragments = Array(repeating: nil, count: fragmentCount)
    }

    func insert(index: Int, payload: Data) {
        guard index >= 0, index < fragmentCount, fragments[index] == nil else { return }
        fragments[index] = payload
        receivedCount += 1
    }

    func recoverSingleMissingWithParity() -> Bool {
        guard receivedCount == fragmentCount - 1, let parity else { return false }
        guard let missing = fragments.firstIndex(where: { $0 == nil }) else { return false }
        var recovered = [UInt8](repeating: 0, count: parity.count)
        parity.copyBytes(to: &recovered, count: parity.count)
        for fragment in fragments.compactMap({ $0 }) {
            fragment.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let count = min(bytes.count, recovered.count)
                for i in 0..<count { recovered[i] ^= bytes[i] }
            }
        }
        let offset = missing * LANVideoWire.maxFragmentPayload
        let expected = min(LANVideoWire.maxFragmentPayload, max(0, frameLength - offset))
        guard expected > 0, expected <= recovered.count else { return false }
        fragments[missing] = Data(recovered.prefix(expected))
        receivedCount += 1
        return true
    }

    func completeData() -> Data? {
        guard receivedCount == fragmentCount else { return nil }
        var result = Data(capacity: frameLength)
        for fragment in fragments {
            guard let fragment else { return nil }
            result.append(fragment)
        }
        guard result.count >= frameLength else { return nil }
        if result.count > frameLength { result.removeSubrange(frameLength..<result.count) }
        return result
    }
}

struct LANVideoTelemetry: Sendable {
    let packetsPerSecond: Double
    let recoveredFrames: UInt64
    let lostFrames: UInt64
    let lateFrames: UInt64
    let frameReceiveMsAverage: Double
    let frameReceiveMsMax: Double
}

/// A no-jitter-buffer, newest-frame LAN video receiver.
///
/// Real-time mirroring should never wait for a missing video packet: doing so
/// turns a 1 ms LAN RTT into a 50-300 ms interaction stall. We use one XOR parity
/// datagram per encoded frame to repair one lost fragment, then immediately drop
/// an unrecoverable frame and wait for a fresh keyframe.
final class LANVideoReceiver: @unchecked Sendable {
    let localPort: UInt16
    let sessionToken: UInt64

    var onVideo: (@Sendable (VideoPacket) -> Void)?
    var onFrameLoss: (@Sendable () -> Void)?
    var onTelemetry: (@Sendable (LANVideoTelemetry) -> Void)?

    private let fd: Int32
    private let queue = DispatchQueue(label: "com.ioscpy.lan-video", qos: .userInteractive)
    private var source: DispatchSourceRead?
    private var assemblies: [UInt32: LANFrameAssembly] = [:]
    private var lastDeliveredSequence: UInt32?
    private var waitingForKeyframe = false
    private var stopped = false
    private let deliveryLock = NSLock()
    private var deliveredFrames: UInt64 = 0
    private var lastDeliveredAtNanos: UInt64 = 0
    private var telemetryStartedAt = DispatchTime.now().uptimeNanoseconds
    private var telemetryPackets: UInt64 = 0
    private var telemetryRecovered: UInt64 = 0
    private var telemetryLost: UInt64 = 0
    private var telemetryLate: UInt64 = 0
    private var telemetryFrameReceiveMsTotal: Double = 0
    private var telemetryFrameReceiveMsMax: Double = 0
    private var telemetryCompletedFrames: UInt64 = 0

    init() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw ConnectionFailure.processFailed("无法创建局域网视频 UDP socket")
        }

        var receiveBuffer = 4 * 1024 * 1024
        setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer)))
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw ConnectionFailure.processFailed("无法绑定局域网视频 UDP 端口")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            throw ConnectionFailure.processFailed("无法读取局域网视频 UDP 端口")
        }
        let boundPort = UInt16(bigEndian: bound.sin_port)
        var random: UInt64 = 0
        arc4random_buf(&random, MemoryLayout<UInt64>.size)
        self.fd = socketFD
        self.localPort = boundPort
        self.sessionToken = random == 0 ? 1 : random
    }

    deinit { stop() }

    func start() {
        guard source == nil, !stopped else { return }
        let created = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        created.setEventHandler { [weak self] in self?.drainDatagrams() }
        created.setCancelHandler { [fd] in close(fd) }
        source = created
        created.resume()
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            assemblies.removeAll(keepingCapacity: false)
            source?.cancel()
            source = nil
        }
    }

    func mediaBindPayload() -> Data {
        var data = Data(capacity: 12)
        data.appendBE(localPort)
        data.appendBE(UInt16(0))
        data.appendBE(sessionToken)
        return data
    }

    func hasDeliveredFrame() -> Bool {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return deliveredFrames > 0
    }

    func secondsSinceLastDeliveredFrame() -> Double? {
        deliveryLock.lock()
        let last = lastDeliveredAtNanos
        deliveryLock.unlock()
        guard last > 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- last) / 1_000_000_000
    }

    private func drainDatagrams() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !stopped {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                return
            }
            if count == 0 { break }
            handleDatagram(Data(buffer.prefix(count)))
        }
        expireOldAssemblies()
    }

    private func handleDatagram(_ datagram: Data) {
        telemetryPackets &+= 1
        defer { emitTelemetryIfNeeded() }
        guard datagram.count >= LANVideoWire.headerSize,
              datagram.readBE(UInt32.self, at: 0) == LANVideoWire.magic,
              datagram[4] == LANVideoWire.version,
              Int(datagram.readBE(UInt16.self, at: 6)) == LANVideoWire.headerSize,
              datagram.readBE(UInt64.self, at: 8) == sessionToken else { return }

        let flags = datagram[5]
        let sequence = datagram.readBE(UInt32.self, at: 16)
        let frameLength = Int(datagram.readBE(UInt32.self, at: 20))
        let fragmentIndex = Int(datagram.readBE(UInt16.self, at: 24))
        let fragmentCount = Int(datagram.readBE(UInt16.self, at: 26))
        let payloadLength = Int(datagram.readBE(UInt16.self, at: 28))
        guard frameLength >= 16, frameLength <= Wire.maxPayload,
              fragmentCount > 0, fragmentCount <= 4096,
              payloadLength >= 0,
              LANVideoWire.headerSize + payloadLength <= datagram.count else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let assembly: LANFrameAssembly
        if let existing = assemblies[sequence],
           existing.frameLength == frameLength,
           existing.fragmentCount == fragmentCount {
            assembly = existing
        } else {
            assembly = LANFrameAssembly(
                frameLength: frameLength,
                fragmentCount: fragmentCount,
                createdAtNanos: now
            )
            assemblies[sequence] = assembly
            // Never build latency by retaining a long queue of partially received
            // frames. Four is enough for normal Wi-Fi reordering at 120 FPS.
            if assemblies.count > 4 {
                let oldest = assemblies.min { $0.value.createdAtNanos < $1.value.createdAtNanos }?.key
                if let oldest, oldest != sequence {
                    assemblies.removeValue(forKey: oldest)
                    noteLoss()
                }
            }
        }

        let payload = datagram.subdata(in: LANVideoWire.headerSize..<(LANVideoWire.headerSize + payloadLength))
        if (flags & LANVideoWire.parityFlag) != 0 {
            assembly.parity = payload
        } else {
            assembly.insert(index: fragmentIndex, payload: payload)
        }

        if assembly.receivedCount != fragmentCount,
           assembly.recoverSingleMissingWithParity() {
            telemetryRecovered &+= 1
        }
        guard let body = assembly.completeData() else { return }
        assemblies.removeValue(forKey: sequence)
        let completionMs = Double(now &- assembly.createdAtNanos) / 1_000_000
        telemetryFrameReceiveMsTotal += completionMs
        telemetryFrameReceiveMsMax = max(telemetryFrameReceiveMsMax, completionMs)
        telemetryCompletedFrames &+= 1

        if let last = lastDeliveredSequence {
            let delta = Int32(bitPattern: sequence &- last)
            if delta <= 0 {
                // Late completion of an older frame. Rendering it would move the
                // user's view backwards in time, so newest-frame policy wins.
                telemetryLate &+= 1
                return
            }
            if delta > 1 {
                // A whole frame was not recoverable. For an inter-frame codec all
                // dependent P-frames are stale, so request an IDR immediately.
                telemetryLost &+= UInt64(delta - 1)
                noteLoss()
            }
        }
        lastDeliveredSequence = sequence
        guard let packet = parseVideoPacket(body) else {
            noteLoss()
            return
        }
        if waitingForKeyframe {
            guard packet.isKeyframe else { return }
            waitingForKeyframe = false
        }
        deliveryLock.lock()
        deliveredFrames &+= 1
        lastDeliveredAtNanos = DispatchTime.now().uptimeNanoseconds
        deliveryLock.unlock()
        onVideo?(packet)
    }

    private func expireOldAssemblies() {
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline: UInt64 = 35_000_000 // ~4 frames at 120 FPS
        let expired = assemblies.compactMap { key, value in
            now &- value.createdAtNanos > deadline ? key : nil
        }
        guard !expired.isEmpty else { return }
        expired.forEach { assemblies.removeValue(forKey: $0) }
        noteLoss()
    }

    private func noteLoss() {
        if !waitingForKeyframe {
            waitingForKeyframe = true
            onFrameLoss?()
        }
    }

    private func emitTelemetryIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- telemetryStartedAt
        guard elapsed >= 1_000_000_000 else { return }
        let seconds = max(Double(elapsed) / 1_000_000_000, 0.001)
        let sample = LANVideoTelemetry(
            packetsPerSecond: Double(telemetryPackets) / seconds,
            recoveredFrames: telemetryRecovered,
            lostFrames: telemetryLost,
            lateFrames: telemetryLate,
            frameReceiveMsAverage: telemetryCompletedFrames > 0
                ? telemetryFrameReceiveMsTotal / Double(telemetryCompletedFrames) : 0,
            frameReceiveMsMax: telemetryFrameReceiveMsMax
        )
        telemetryStartedAt = now
        telemetryPackets = 0
        telemetryRecovered = 0
        telemetryLost = 0
        telemetryLate = 0
        telemetryFrameReceiveMsTotal = 0
        telemetryFrameReceiveMsMax = 0
        telemetryCompletedFrames = 0
        onTelemetry?(sample)
    }
}
