import AppKit
import CoreVideo
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let store = SettingsStore()

    @Published var screen: AppScreen = .home
    @Published var status: SessionStatus = .idle
    @Published var currentDeviceID: String?
    @Published var activeMode: ConnectionMode = .usb
    @Published var discoveredUDIDs: [String] = []
    @Published var showingSettings = false
    @Published var showingPairing = false
    @Published var pairingCode = ""
    @Published var toolbarVisible = false
    @Published var blackScreenEnabled = false
    @Published var stats = RuntimeStats()
    @Published var frameSize = CGSize(width: 393, height: 852)

    private var session: IOSCPYSession?
    private let decoder = VideoDecoder()
    private let audioPlayer = AudioPlayer()
    private weak var mirrorView: MirrorMetalView?
    private var latestFrame: (CVPixelBuffer, Int)?
    private var pendingPairing: (DeviceProfile, ConnectionMode)?
    private var reconnectTask: Task<Void, Never>?
    private var userDisconnected = false
    private var receivedFrames = 0
    private var presentedFrames = 0
    private var receivedBytes = 0
    private var lastStatsAt = ContinuousClock.now
    private var toolbarHideTask: Task<Void, Never>?
    private let hostID: String

    init() {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "host-id"), !existing.isEmpty {
            hostID = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: "host-id")
            hostID = created
        }

        decoder.onPixelBuffer = { [weak self] envelope, width, height, orientation in
            Task { @MainActor [weak self] in
                self?.handleDecodedFrame(envelope.buffer, width: width, height: height, orientation: orientation)
            }
        }
        decoder.onDecodeError = { error in
            NSLog("[ioscpy] decode: %@", error)
        }
    }

    var devices: [DeviceProfile] { store.state.devices }

    var currentDevice: DeviceProfile? {
        guard let currentDeviceID else { return nil }
        return store.state.devices.first { $0.id == currentDeviceID }
    }

    func launch() {
        Task {
            await refreshDevices()
            guard store.state.preferences.autoConnectLastDevice,
                  let id = store.state.preferences.lastDeviceID,
                  let device = store.state.devices.first(where: { $0.id == id }),
                  device.autoConnect else { return }
            let mode = device.preferredMode
            if mode == .usb, let udid = device.udid, !discoveredUDIDs.contains(udid) { return }
            await connect(device: device, mode: mode, automatic: true)
        }
    }

    func refreshDevices() async {
        let udids = await USBDiscovery.listUDIDs()
        discoveredUDIDs = udids
        var changed = false
        for udid in udids where !store.state.devices.contains(where: { $0.udid == udid }) {
            var profile = DeviceProfile(name: "iPhone", udid: udid)
            profile.preferredMode = .usb
            store.state.devices.append(profile)
            changed = true
        }
        if changed { store.save() }
    }

    func addLANDevice() {
        let profile = DeviceProfile(
            name: "局域网 iPhone",
            preferredMode: .lan,
            autoConnect: false
        )
        store.state.devices.append(profile)
        store.save()
        currentDeviceID = profile.id
        showingSettings = true
    }

    func connect(device: DeviceProfile, mode: ConnectionMode, automatic: Bool = false) async {
        guard session == nil else { return }
        userDisconnected = false
        reconnectTask?.cancel()
        currentDeviceID = device.id
        activeMode = mode
        screen = .connecting
        status = .connecting(automatic ? "正在自动连接 \(device.name)…" : "正在连接 \(device.name)…")
        AppWindowManager.shared.setMirrorMode(false)
        do {
            try await establish(device: device, mode: mode, pairCode: nil)
        } catch ConnectionFailure.pairingRequired(let challenge) {
            pendingPairing = (device, mode)
            pairingCode = ""
            showingPairing = true
            status = .pairing(challenge.message)
            screen = .home
        } catch {
            status = .failed(error.localizedDescription)
            screen = .home
        }
    }

    private func establish(device: DeviceProfile, mode: ConnectionMode, pairCode: String?) async throws {
        let connected = try await IOSCPYSession.connect(
            profile: device,
            mode: mode,
            hostID: hostID,
            pairCode: pairCode
        )
        configureCallbacks(connected)
        session = connected

        var updated = device
        if let token = connected.issuedPairToken {
            updated.pairToken = token
            updated.pairExpiresAt = connected.pairExpiresAt ?? Date().addingTimeInterval(30 * 24 * 3600)
        }
        updated.preferredMode = mode
        updated.lastConnectedAt = Date()
        store.upsert(updated)
        store.state.preferences.lastDeviceID = updated.id
        store.save()
        currentDeviceID = updated.id
        activeMode = mode
        blackScreenEnabled = false

        try await connected.start(settings: updated.video, audio: updated.audioEnabled)
        screen = .mirror
        status = .connected("\(mode.title) · \(connected.capabilities.deviceModel) · iOS \(connected.capabilities.iosVersion)")
        stats.transport = mode.title
        AppWindowManager.shared.setMirrorMode(true)
        AppWindowManager.shared.setAlwaysOnTop(updated.alwaysOnTop)
        AppWindowManager.shared.updateAspect(frameSize)
        revealToolbar()

        connected.systemAction(3)
        if !updated.lockPassword.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
            await sendUnlockPassword(updated.lockPassword)
        }
    }

    private func configureCallbacks(_ connected: IOSCPYSession) {
        connected.onVideo = { [weak self] packet in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receivedFrames += 1
                self.receivedBytes += packet.bytes.count
                self.decoder.decode(packet)
                self.updateStatsClock()
            }
        }
        connected.onStats = { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                if let dropped = object["dropped_frames"] as? NSNumber {
                    self?.stats.droppedFrames = dropped.uint64Value
                }
            }
        }
        connected.onLog = { message in NSLog("[ioscpy] device: %@", message) }
        connected.onAudio = { [weak self] packet in self?.audioPlayer.enqueue(packet) }
        connected.onRTT = { [weak self] value in
            Task { @MainActor [weak self] in self?.stats.latencyMs = value }
        }
        connected.onDisconnected = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleDisconnect(error)
            }
        }
    }

    func submitPairingCode() {
        let code = pairingCode.filter(\.isNumber)
        guard code.count == 4, let pendingPairing else { return }
        showingPairing = false
        status = .connecting("正在验证配对码…")
        screen = .connecting
        Task {
            do {
                try await establish(device: pendingPairing.0, mode: pendingPairing.1, pairCode: code)
                self.pendingPairing = nil
            } catch ConnectionFailure.pairingRequired(let error) {
                self.screen = .home
                self.status = .failed(error.message)
                self.showingPairing = true
            } catch {
                self.screen = .home
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        userDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        session?.stop(userInitiated: true)
        session = nil
        decoder.invalidate()
        audioPlayer.stop()
        blackScreenEnabled = false
        screen = .home
        status = .idle
        AppWindowManager.shared.setMirrorMode(false)
    }

    private func handleDisconnect(_ error: Error?) {
        session = nil
        decoder.invalidate()
        audioPlayer.stop()
        guard !userDisconnected, let device = currentDevice else {
            screen = .home
            return
        }
        scheduleReconnect(device: device, mode: activeMode, reason: error?.localizedDescription ?? "连接中断")
    }

    private func scheduleReconnect(device: DeviceProfile, mode: ConnectionMode, reason: String) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let ladder: [Double] = [0, 0.25, 0.5, 1, 2, 4, 8, 15, 30]
            var attempt = 0
            while let self, !Task.isCancelled, !self.userDisconnected {
                let base = ladder[min(attempt, ladder.count - 1)]
                let jitter = base == 0 ? 0 : Double.random(in: -0.2...0.2) * base
                let delay = max(0, base + jitter)
                self.status = .reconnecting(attempt + 1, reason)
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if Task.isCancelled || self.userDisconnected { return }
                do {
                    try await self.establish(device: device, mode: mode, pairCode: nil)
                    return
                } catch ConnectionFailure.pairingRequired {
                    self.screen = .home
                    self.status = .failed("30 天信任已失效，需要重新配对")
                    return
                } catch {
                    attempt += 1
                }
            }
        }
    }

    func attachMirrorView(_ view: MirrorMetalView) {
        mirrorView = view
        view.onTouch = { [weak self] phase, x, y in self?.session?.sendTouch(phase: phase, x: x, y: y) }
        view.onScroll = { [weak self] payload in self?.session?.sendScroll(payload) }
        view.onText = { [weak self] text in self?.session?.sendText(text) }
        view.onKey = { [weak self] code in self?.session?.sendKey(code) }
        view.onPointerActivity = { [weak self] in Task { @MainActor in self?.revealToolbar() } }
        view.onFramePresented = { [weak self] in
            Task { @MainActor [weak self] in
                self?.presentedFrames += 1
                self?.updateStatsClock()
            }
        }
        if let latestFrame { view.update(pixelBuffer: latestFrame.0, orientation: latestFrame.1) }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    private func handleDecodedFrame(_ buffer: CVPixelBuffer, width: Int, height: Int, orientation: Int) {
        latestFrame = (buffer, orientation)
        mirrorView?.update(pixelBuffer: buffer, orientation: orientation)
        let upright = (orientation == 3 || orientation == 4)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        if upright.width > 0, upright.height > 0, upright != frameSize {
            frameSize = upright
            AppWindowManager.shared.updateAspect(upright)
        }
    }

    private func updateStatsClock() {
        let elapsed = lastStatsAt.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds >= 1 else { return }
        stats.receiveFPS = Double(receivedFrames) / seconds
        stats.presentFPS = Double(presentedFrames) / seconds
        stats.bitrateMbps = Double(receivedBytes * 8) / seconds / 1_000_000
        receivedFrames = 0
        presentedFrames = 0
        receivedBytes = 0
        lastStatsAt = .now
    }

    func revealToolbar() {
        toolbarVisible = true
        toolbarHideTask?.cancel()
        let delay = store.state.preferences.toolbarAutoHideDelay
        toolbarHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.toolbarVisible = false
        }
    }

    func toggleAlwaysOnTop() {
        guard var device = currentDevice else { return }
        device.alwaysOnTop.toggle()
        store.upsert(device)
        AppWindowManager.shared.setAlwaysOnTop(device.alwaysOnTop)
    }

    func toggleBlackScreen() {
        guard let session else { return }
        blackScreenEnabled.toggle()
        session.setBlackScreen(blackScreenEnabled)
        if blackScreenEnabled {
            session.setAudio(true)
        } else if let device = currentDevice {
            session.setAudio(device.audioEnabled)
        }
    }

    func updateCurrentDevice(_ transform: (inout DeviceProfile) -> Void, applyVideo: Bool = false) {
        guard var device = currentDevice else { return }
        transform(&device)
        device.video.normalize()
        store.upsert(device)
        if applyVideo { Task { try? await session?.updateVideo(device.video) } }
        AppWindowManager.shared.setAlwaysOnTop(device.alwaysOnTop)
    }

    func setAudioEnabled(_ enabled: Bool) {
        updateCurrentDevice { $0.audioEnabled = enabled }
        if !blackScreenEnabled { session?.setAudio(enabled) }
    }

    func sendUnlockPassword(_ password: String) async {
        guard !password.isEmpty else { return }
        try? await session?.send(type: .unlock, payload: Data(password.utf8))
    }

    func systemAction(_ code: UInt16) { session?.systemAction(code) }
}

@MainActor
final class AppWindowManager {
    static let shared = AppWindowManager()
    weak var window: NSWindow?
    private var mirrorMode = false

    func attach(_ window: NSWindow) {
        self.window = window
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]
        window.minSize = NSSize(width: 320, height: 480)
    }

    func setMirrorMode(_ enabled: Bool) {
        guard let window else { return }
        mirrorMode = enabled
        if enabled {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.borderless, .resizable, .miniaturizable]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
        } else {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentAspectRatio = .zero
            window.minSize = NSSize(width: 760, height: 560)
            let current = window.frame
            if current.width < 760 || current.height < 560 {
                window.setContentSize(NSSize(width: 860, height: 620))
                window.center()
            }
        }
    }

    func updateAspect(_ size: CGSize) {
        guard mirrorMode, let window, size.width > 0, size.height > 0 else { return }
        window.contentAspectRatio = size
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(480, screen.height * 0.86)
        let maxWidth = max(320, screen.width * 0.78)
        let scale = min(maxHeight / size.height, maxWidth / size.width, 1)
        let target = NSSize(width: max(320, size.width * scale), height: max(480, size.height * scale))
        if window.frame.width > maxWidth || window.frame.height > maxHeight || window.frame.width < 260 {
            window.setContentSize(target)
            window.center()
        }
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        window?.level = enabled ? .floating : .normal
    }
}
