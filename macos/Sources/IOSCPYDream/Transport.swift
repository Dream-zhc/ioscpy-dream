import Darwin
import Foundation
import Network

final class TCPTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.ioscpy.transport", qos: .userInteractive)

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ConnectionFailure.invalidAddress
        }
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeOnce { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    gate.resumeOnce { continuation.resume(throwing: error) }
                case .cancelled:
                    gate.resumeOnce { continuation.resume(throwing: ConnectionFailure.disconnected) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func enqueue(_ data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw ConnectionFailure.protocolError("负数读取长度") }
        if count == 0 { return Data() }
        var result = Data(capacity: count)
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await receive(minimum: 1, maximum: remaining)
            guard !chunk.isEmpty else { throw ConnectionFailure.disconnected }
            result.append(chunk)
        }
        return result
    }

    private func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ConnectionFailure.disconnected)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

final class USBForward: @unchecked Sendable {
    let localPort: UInt16
    private let process: Process

    init(udid: String) async throws {
        guard let iproxy = ToolLocator.find("iproxy") else {
            throw ConnectionFailure.toolMissing("iproxy（brew install libimobiledevice）")
        }
        localPort = try Self.reservePort()
        process = Process()
        process.executableURL = URL(fileURLWithPath: iproxy)
        process.arguments = ["\(localPort):\(Wire.defaultPort)", "-u", udid, "-l"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if !process.isRunning {
                throw ConnectionFailure.processFailed("USB 转发进程提前退出")
            }
            if Self.canConnect(port: localPort) { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        process.terminate()
        throw ConnectionFailure.processFailed("无法通过 USB 连接 iPhone，请检查数据线、信任状态和 iproxy")
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private static func reservePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionFailure.processFailed("无法分配本地端口") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw ConnectionFailure.processFailed("无法绑定本地端口") }
        var output = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let grc = withUnsafeMutablePointer(to: &output) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard grc == 0 else { throw ConnectionFailure.processFailed("无法读取本地端口") }
        return UInt16(bigEndian: output.sin_port)
    }

    private static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

enum ToolLocator {
    static func find(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        if let direct = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

enum USBDiscovery {
    static func listUDIDs() async -> [String] {
        guard let tool = ToolLocator.find("idevice_id") else { return [] }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-l"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            } catch {
                return []
            }
        }.value
    }
}

final class IOSCPYSession: @unchecked Sendable {
    let mode: ConnectionMode
    let profileID: String
    private let transport: TCPTransport
    private let usbForward: USBForward?
    private let sendLock = NSLock()
    private let realtimeSendQueue = DispatchQueue(
        label: "com.ioscpy.realtime-control",
        qos: .userInteractive
    )
    private var readTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var stopped = false
    private var sequence: UInt64 = 1

    let capabilities: Capabilities
    let issuedPairToken: String?
    let pairExpiresAt: Date?

    var onVideo: (@Sendable (VideoPacket) -> Void)?
    var onAudio: (@Sendable (Data) -> Void)?
    var onStats: (@Sendable (Data) -> Void)?
    var onRTT: (@Sendable (Double) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onDisconnected: (@Sendable (Error?) -> Void)?

    private init(
        mode: ConnectionMode,
        profileID: String,
        transport: TCPTransport,
        usbForward: USBForward?,
        capabilities: Capabilities,
        issuedPairToken: String?,
        pairExpiresAt: Date?
    ) {
        self.mode = mode
        self.profileID = profileID
        self.transport = transport
        self.usbForward = usbForward
        self.capabilities = capabilities
        self.issuedPairToken = issuedPairToken
        self.pairExpiresAt = pairExpiresAt
    }

    static func connect(
        profile: DeviceProfile,
        mode: ConnectionMode,
        hostID: String,
        pairCode: String? = nil
    ) async throws -> IOSCPYSession {
        let forward: USBForward?
        let host: String
        let port: UInt16
        switch mode {
        case .usb:
            guard let udid = profile.udid, !udid.isEmpty else {
                throw ConnectionFailure.processFailed("该设备没有 USB UDID")
            }
            let created = try await USBForward(udid: udid)
            forward = created
            host = "127.0.0.1"
            port = created.localPort
        case .lan:
            guard !profile.lanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65535).contains(profile.lanPort) else {
                throw ConnectionFailure.invalidAddress
            }
            forward = nil
            host = profile.lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
            port = UInt16(profile.lanPort)
        }

        let transport = try TCPTransport(host: host, port: port)
        do {
            do {
                try await transport.start()
            } catch {
                if mode == .lan {
                    throw ConnectionFailure.processFailed(
                        "无法连接 \(host):\(port)。请确认 Mac 与 iPhone 在同一局域网、IP 正确，并已安装 dream.3 手机端。系统错误：\(error.localizedDescription)"
                    )
                }
                throw error
            }
            let hello = HelloPayload(
                nonce: randomHex(byteCount: 16),
                hostID: hostID,
                hostName: Host.current().localizedName ?? "Mac",
                pairToken: mode == .lan ? profile.pairToken : nil,
                pairCode: pairCode
            )
            let helloData = try JSONEncoder().encode(hello)
            try await transport.send(makeWireFrame(type: .hello, payload: helloData))
            let response = try await readFrame(from: transport)
            if response.type == .error {
                let daemonError = try JSONDecoder().decode(DaemonErrorPayload.self, from: response.payload)
                if daemonError.code == "PAIR_REQUIRED" || daemonError.code == "PAIR_CODE_INVALID" {
                    throw ConnectionFailure.pairingRequired(daemonError)
                }
                throw ConnectionFailure.protocolError("\(daemonError.code)：\(daemonError.message)")
            }
            guard response.type == .helloAck else {
                throw ConnectionFailure.protocolError("握手响应类型错误：\(response.type.rawValue)")
            }
            let decoder = JSONDecoder.configured
            let ack = try decoder.decode(HelloAck.self, from: response.payload)
            guard ack.protocolVersion == Wire.version else {
                throw ConnectionFailure.protocolError("协议版本不一致：Mac \(Wire.version)，iPhone \(ack.protocolVersion)")
            }
            try await transport.send(makeWireFrame(type: .authenticate, payload: Data(ack.sessionToken.utf8)))
            return IOSCPYSession(
                mode: mode,
                profileID: profile.id,
                transport: transport,
                usbForward: forward,
                capabilities: ack.capabilities,
                issuedPairToken: ack.pairToken,
                pairExpiresAt: ack.pairExpiresAt
            )
        } catch {
            transport.cancel()
            forward?.stop()
            throw error
        }
    }

    private static func readFrame(from transport: TCPTransport) async throws -> WireFrame {
        let header = try await transport.receiveExactly(Wire.headerSize)
        guard header.readBE(UInt32.self, at: 0) == Wire.magic else {
            throw ConnectionFailure.protocolError("收到无效协议魔数")
        }
        let version = header.readBE(UInt16.self, at: 4)
        guard version == Wire.version else {
            throw ConnectionFailure.protocolError("协议版本不一致：\(version)")
        }
        let typeRaw = header.readBE(UInt16.self, at: 6)
        guard let type = MessageType(rawValue: typeRaw) else {
            throw ConnectionFailure.protocolError("未知消息类型：\(typeRaw)")
        }
        let flags = header.readBE(UInt32.self, at: 8)
        let streamID = header.readBE(UInt64.self, at: 12)
        let sequence = header.readBE(UInt64.self, at: 20)
        let length = Int(header.readBE(UInt32.self, at: 28))
        guard length <= Wire.maxPayload else {
            throw ConnectionFailure.protocolError("消息过大：\(length)")
        }
        let payload = try await transport.receiveExactly(length)
        return WireFrame(type: type, flags: flags, streamID: streamID, sequence: sequence, payload: payload)
    }

    func start(settings: VideoSettings, audio: Bool) async throws {
        try await send(type: .keyboardMode, payload: Data([1]))
        try await send(type: .audioMode, payload: Data([audio ? 1 : 0]))
        try await send(type: .startStream, payload: makeStreamConfig(settings))
        readTask = Task.detached(priority: .high) { [weak self] in
            await self?.readLoop()
        }
        pingTask = Task.detached(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, !self.stopped {
                try? await Task.sleep(for: .seconds(2))
                var sentAt = DispatchTime.now().uptimeNanoseconds.bigEndian
                let payload = Swift.withUnsafeBytes(of: &sentAt) { Data($0) }
                try? await self.send(type: .ping, payload: payload)
            }
        }
    }

    private func readLoop() async {
        do {
            while !stopped, !Task.isCancelled {
                let frame = try await Self.readFrame(from: transport)
                switch frame.type {
                case .videoFrame:
                    if let packet = parseVideoPacket(frame.payload) { onVideo?(packet) }
                case .audioFrame:
                    onAudio?(frame.payload)
                case .stats:
                    onStats?(frame.payload)
                case .pong:
                    if frame.payload.count >= 8 {
                        let sentAt = frame.payload.readBE(UInt64.self, at: 0)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if sentAt <= now {
                            onRTT?(Double(now - sentAt) / 1_000_000)
                        }
                    }
                case .log:
                    if let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                       let message = object["message"] as? String {
                        onLog?(message)
                    }
                case .error:
                    let payload = try? JSONDecoder().decode(DaemonErrorPayload.self, from: frame.payload)
                    if payload?.fatal == true {
                        throw ConnectionFailure.protocolError(payload?.message ?? "iPhone 端返回致命错误")
                    }
                default:
                    break
                }
            }
        } catch {
            if !stopped { onDisconnected?(error) }
        }
    }

    func send(type: MessageType, payload: Data = Data(), streamID: UInt64 = Wire.channelControl) async throws {
        let current = nextSequence()
        try await transport.send(makeWireFrame(type: type, streamID: streamID, sequence: current, payload: payload))
    }

    private func nextSequence() -> UInt64 {
        sendLock.lock()
        defer { sendLock.unlock() }
        let current = sequence
        sequence &+= 1
        return current
    }

    private func enqueue(type: MessageType, payload: Data = Data(), streamID: UInt64 = Wire.channelControl) {
        let current = nextSequence()
        let frame = makeWireFrame(type: type, streamID: streamID, sequence: current, payload: payload)
        realtimeSendQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.transport.enqueue(frame) { error in
                if let error {
                    NSLog("[ioscpy] realtime send failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func updateVideo(_ settings: VideoSettings) async throws {
        try await send(type: .startStream, payload: makeStreamConfig(settings))
    }

    func sendTouch(phase: UInt8, x: Float, y: Float) {
        enqueue(type: .inputTouch, payload: makeTouchPayload(phase: phase, x: x, y: y))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(type: .inputText, payload: Data(text.utf8))
    }

    func sendKey(_ code: UInt8) {
        enqueue(type: .inputKey, payload: Data([code]))
    }

    func sendScroll(_ payload: Data) {
        enqueue(type: .inputScroll, payload: payload)
    }

    func systemAction(_ code: UInt16) {
        var value = code.bigEndian
        let payload = Swift.withUnsafeBytes(of: &value) { Data($0) }
        enqueue(type: .systemAction, payload: payload)
    }

    func setBlackScreen(_ enabled: Bool) {
        enqueue(type: .displayMode, payload: Data([enabled ? 1 : 0]))
    }

    func setAudio(_ enabled: Bool) {
        enqueue(type: .audioMode, payload: Data([enabled ? 1 : 0]))
    }

    func stop(userInitiated: Bool = true) {
        guard !stopped else { return }
        stopped = true
        readTask?.cancel()
        pingTask?.cancel()
        Task { try? await send(type: .stopStream) }
        transport.cancel()
        usbForward?.stop()
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func resumeOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        action()
    }
}
