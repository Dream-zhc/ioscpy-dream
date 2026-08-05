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
    private lazy var decodePump = VideoDecodePump(decoder: decoder)
    private let audioPlayer = AudioPlayer()
    private let performanceCounters = PerformanceCounters()
    let frameMailbox = VideoFrameMailbox()
    private weak var mirrorView: MirrorMetalView?
    private var pendingPairing: (DeviceProfile, ConnectionMode)?
    private var reconnectTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var userDisconnected = false
    private var didLaunch = false
    private var toolbarHideTask: Task<Void, Never>?
    private var pointerInsideAccessory = false
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

        let mailbox = frameMailbox
        decoder.onPixelBuffer = { [weak self] envelope, width, height, orientation in
            let geometryChanged = mailbox.publish(
                envelope.buffer,
                width: width,
                height: height,
                orientation: orientation
            )
            if geometryChanged {
                Task { @MainActor [weak self] in
                    self?.handleFrameGeometry(width: width, height: height, orientation: orientation)
                }
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
        guard !didLaunch else { return }
        didLaunch = true
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
        startStatsTask()
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
        let decoder = self.decoder
        let decodePump = self.decodePump
        let counters = performanceCounters
        decoder.onDecodeError = { [weak connected] error in
            NSLog("[ioscpy] decode: %@", error)
            connected?.requestKeyframe()
        }
        decodePump.onNeedKeyframe = { [weak connected] in connected?.requestKeyframe() }
        decodePump.onDroppedStaleChain = {
            NSLog("[ioscpy] decoder backlog discarded; requesting fresh keyframe")
        }
        connected.onVideo = { packet in
            counters.recordReceived(bytes: packet.bytes.count)
            decodePump.submit(packet)
        }
        connected.onStats = { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let windowMs = max((object["window_ms"] as? NSNumber)?.doubleValue ?? 1000, 1)
                let scale = 1000.0 / windowMs
                if let captured = object["captured_frames"] as? NSNumber {
                    self.stats.captureFPS = captured.doubleValue * scale
                }
                if let encoded = object["encoded_frames"] as? NSNumber {
                    self.stats.encodeFPS = encoded.doubleValue * scale
                }
                if let sent = object["sent_frames"] as? NSNumber {
                    self.stats.sourceFPS = sent.doubleValue * scale
                }
                if let dropped = object["dropped_frames"] as? NSNumber {
                    self.stats.droppedFrames = dropped.uint64Value
                }
                self.stats.captureMs = (object["capture_ms_avg"] as? NSNumber)?.doubleValue ?? 0
                self.stats.encodeMs = (object["encode_ms_avg"] as? NSNumber)?.doubleValue ?? 0
                self.stats.sendMs = (object["send_ms_avg"] as? NSNumber)?.doubleValue ?? 0
                self.stats.effectiveDimension = (object["max_dimension"] as? NSNumber)?.intValue ?? 0
                self.stats.encodeInFlight = (object["encode_inflight"] as? NSNumber)?.intValue ?? 0
                self.stats.sendBacklog = (object["send_backlog"] as? NSNumber)?.intValue ?? 0

                if self.stats.sourceFPS > 0, self.stats.sourceFPS < 90 {
                    NSLog(
                        "[ioscpy] pipeline cap=%.1f encode=%.1f sent=%.1f capture=%.2fms encode=%.2fms send=%.2fms inFlight=%d backlog=%d max=%d",
                        self.stats.captureFPS,
                        self.stats.encodeFPS,
                        self.stats.sourceFPS,
                        self.stats.captureMs,
                        self.stats.encodeMs,
                        self.stats.sendMs,
                        self.stats.encodeInFlight,
                        self.stats.sendBacklog,
                        self.stats.effectiveDimension
                    )
                }
            }
        }
        connected.onLog = { message in NSLog("[ioscpy] device: %@", message) }
        connected.onAudio = { [weak self] packet in self?.audioPlayer.enqueue(packet) }
        connected.onRTT = { [weak self] value in
            Task { @MainActor [weak self] in self?.stats.latencyMs = value }
        }
        connected.onDisconnected = { [weak self, weak connected] error in
            Task { @MainActor [weak self] in
                guard let self, let connected, self.session === connected else { return }
                self.handleDisconnect(error)
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
        statsTask?.cancel()
        statsTask = nil
        session?.stop(userInitiated: true)
        session = nil
        decodePump.reset()
        audioPlayer.stop()
        blackScreenEnabled = false
        screen = .home
        status = .idle
        AppWindowManager.shared.setMirrorMode(false)
    }

    private func handleDisconnect(_ error: Error?) {
        session = nil
        statsTask?.cancel()
        statsTask = nil
        decodePump.reset()
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
        let counters = performanceCounters
        view.onFramePresented = { counters.recordPresented() }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    private func handleFrameGeometry(width: Int, height: Int, orientation: Int) {
        let upright = (orientation == 3 || orientation == 4)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        if upright.width > 0, upright.height > 0, upright != frameSize {
            frameSize = upright
            AppWindowManager.shared.updateAspect(upright)
        }
    }

    private func startStatsTask() {
        statsTask?.cancel()
        performanceCounters.reset()
        statsTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let sample = self.performanceCounters.consume()
                self.stats.receiveFPS = sample.receiveFPS
                self.stats.presentFPS = sample.presentFPS
                self.stats.bitrateMbps = sample.bitrateMbps
            }
        }
    }

    func revealToolbar() {
        toolbarVisible = true
        toolbarHideTask?.cancel()
        guard !pointerInsideAccessory else { return }
        let delay = store.state.preferences.toolbarAutoHideDelay
        toolbarHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.toolbarVisible = false
        }
    }

    func setPointerInsideAccessory(_ inside: Bool) {
        pointerInsideAccessory = inside
        toolbarHideTask?.cancel()
        if inside {
            toolbarVisible = true
        } else {
            revealToolbar()
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
    private var mirrorContentSize = CGSize(width: 393, height: 852)
    private var accessoryPanel: NSPanel?
    private var accessoryHostingView: NSHostingView<AnyView>?
    private var windowObservers: [NSObjectProtocol] = []
    private var mirrorDragStartOrigin: NSPoint?

    func attach(_ window: NSWindow) {
        if self.window === window { return }
        removeWindowObservers()
        self.window = window
        window.isMovableByWindowBackground = !mirrorMode
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]
        window.minSize = NSSize(width: 320, height: 480)
        installWindowObservers(window)
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
            // Every mouse drag inside the phone belongs to iOS. Enabling
            // background dragging here caused macOS to move the whole window
            // instead of forwarding the gesture to the device.
            window.isMovableByWindowBackground = false
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 42
            window.contentView?.layer?.cornerCurve = .continuous
            window.contentView?.layer?.masksToBounds = true
            updateAspect(mirrorContentSize, forceResize: true)
            repositionMirrorAccessory()
        } else {
            hideMirrorAccessory()
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.isMovableByWindowBackground = true
            window.contentView?.layer?.cornerRadius = 0
            window.contentView?.layer?.masksToBounds = false
            window.contentAspectRatio = .zero
            window.minSize = NSSize(width: 760, height: 560)
            let current = window.frame
            if current.width < 760 || current.height < 560 {
                window.setContentSize(NSSize(width: 860, height: 620))
                window.center()
            }
        }
    }

    func updateAspect(_ size: CGSize, forceResize: Bool = false) {
        guard mirrorMode, let window, size.width > 0, size.height > 0 else { return }
        let previousAspect = mirrorContentSize.width / max(mirrorContentSize.height, 1)
        let nextAspect = size.width / size.height
        let orientationChanged = (previousAspect < 1) != (nextAspect < 1)
        mirrorContentSize = size
        window.contentAspectRatio = size
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(520, screen.height * 0.88)
        let maxWidth = max(560, screen.width * 0.82)
        let aspect = size.width / size.height
        let target: NSSize
        if aspect < 1 {
            let height = maxHeight
            target = NSSize(width: height * aspect, height: height)
            window.minSize = NSSize(width: 280, height: 280 / aspect)
        } else {
            let width = maxWidth
            target = NSSize(width: width, height: width / aspect)
            window.minSize = NSSize(width: 560, height: 560 / aspect)
        }
        let current = window.contentLayoutRect.size
        let currentAspect = current.width / max(current.height, 1)
        let ratioWrong = abs(currentAspect - aspect) > 0.01
        if forceResize || orientationChanged || ratioWrong {
            window.setContentSize(target)
            window.center()
        }
        repositionMirrorAccessory()
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        let level: NSWindow.Level = enabled ? .floating : .normal
        window?.level = level
        accessoryPanel?.level = level
    }

    func showMirrorAccessory(model: AppModel, store: SettingsStore) {
        guard let window else { return }
        let root = AnyView(MirrorAccessoryBar(model: model, store: store))
        if let hosting = accessoryHostingView, let panel = accessoryPanel {
            hosting.rootView = root
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            repositionMirrorAccessory()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.level = window.level
        panel.ignoresMouseEvents = false

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 390, height: 52)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        accessoryPanel = panel
        accessoryHostingView = hosting
        window.addChildWindow(panel, ordered: .above)
        repositionMirrorAccessory()
    }

    func setMirrorAccessoryVisible(_ visible: Bool) {
        guard mirrorMode, let panel = accessoryPanel else { return }
        if visible {
            repositionMirrorAccessory()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    func hideMirrorAccessory() {
        guard let panel = accessoryPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        accessoryPanel = nil
        accessoryHostingView = nil
        mirrorDragStartOrigin = nil
    }

    func beginMirrorWindowDrag() {
        mirrorDragStartOrigin = window?.frame.origin
    }

    func updateMirrorWindowDrag(translation: CGSize) {
        guard let window, let start = mirrorDragStartOrigin else { return }
        window.setFrameOrigin(NSPoint(x: start.x + translation.width,
                                      y: start.y - translation.height))
        repositionMirrorAccessory()
    }

    func endMirrorWindowDrag() {
        mirrorDragStartOrigin = nil
    }

    private func repositionMirrorAccessory() {
        guard mirrorMode, let window, let panel = accessoryPanel else { return }
        let parent = window.frame
        let size = panel.frame.size
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 9

        let roomAbove = visible.maxY - parent.maxY
        let roomRight = visible.maxX - parent.maxX
        let roomLeft = parent.minX - visible.minX
        let origin: NSPoint
        if roomAbove >= size.height + gap {
            origin = NSPoint(
                x: min(max(parent.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                y: parent.maxY + gap
            )
        } else if roomRight >= size.width + gap {
            origin = NSPoint(x: parent.maxX + gap,
                             y: min(max(parent.maxY - size.height, visible.minY), visible.maxY - size.height))
        } else if roomLeft >= size.width + gap {
            origin = NSPoint(x: parent.minX - size.width - gap,
                             y: min(max(parent.maxY - size.height, visible.minY), visible.maxY - size.height))
        } else {
            origin = NSPoint(
                x: min(max(parent.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                y: max(visible.minY, parent.minY - size.height - gap)
            )
        }
        panel.setFrameOrigin(origin)
    }

    private func installWindowObservers(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            windowObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.repositionMirrorAccessory()
                }
            })
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }
}

private final class PerformanceCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedFrames = 0
    private var presentedFrames = 0
    private var receivedBytes = 0
    private var startedAt = ContinuousClock.now

    func recordReceived(bytes: Int) {
        lock.lock()
        receivedFrames += 1
        receivedBytes += bytes
        lock.unlock()
    }

    func recordPresented() {
        lock.lock()
        presentedFrames += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        receivedFrames = 0
        presentedFrames = 0
        receivedBytes = 0
        startedAt = .now
        lock.unlock()
    }

    func consume() -> (receiveFPS: Double, presentFPS: Double, bitrateMbps: Double) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = startedAt.duration(to: .now)
        let seconds = max(
            0.001,
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
        let sample = (
            receiveFPS: Double(receivedFrames) / seconds,
            presentFPS: Double(presentedFrames) / seconds,
            bitrateMbps: Double(receivedBytes * 8) / seconds / 1_000_000
        )
        receivedFrames = 0
        presentedFrames = 0
        receivedBytes = 0
        startedAt = .now
        return sample
    }
}
