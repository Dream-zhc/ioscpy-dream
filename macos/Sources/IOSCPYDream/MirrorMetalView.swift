import AppKit
import CoreImage
import CoreVideo
import MetalKit

final class VideoFrameMailbox: @unchecked Sendable {
    struct Snapshot {
        let buffer: CVPixelBuffer
        let width: Int
        let height: Int
        let orientation: Int
        let generation: UInt64
    }

    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var width = 393
    private var height = 852
    private var orientation = 1
    private var generation: UInt64 = 0

    @discardableResult
    func publish(_ buffer: CVPixelBuffer, width: Int, height: Int, orientation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let geometryChanged = self.width != width || self.height != height || self.orientation != orientation
        self.buffer = buffer
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.orientation = orientation
        generation &+= 1
        return geometryChanged
    }

    func snapshot(after previousGeneration: UInt64) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard generation != previousGeneration, let buffer else { return nil }
        return Snapshot(
            buffer: buffer,
            width: width,
            height: height,
            orientation: orientation,
            generation: generation
        )
    }

    func geometry() -> (width: Int, height: Int, orientation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (width, height, orientation)
    }
}

@MainActor
final class MirrorMetalView: MTKView, MTKViewDelegate, @preconcurrency NSTextInputClient {
    var onTouch: ((UInt8, Float, Float) -> Void)?
    var onScroll: ((Data) -> Void)?
    var onText: ((String) -> Void)?
    var onKey: ((UInt8) -> Void)?
    var onHomeGesture: (() -> Void)?
    var onFramePresented: (() -> Void)?
    var onPointerActivity: (() -> Void)?

    private let mailbox: VideoFrameMailbox
    private var renderedGeneration: UInt64 = 0
    private var ciContext: CIContext!
    private var commandQueue: MTLCommandQueue!
    private var colorSpace = CGColorSpaceCreateDeviceRGB()
    private var marked = NSMutableAttributedString()
    private var selection = NSRange(location: 0, length: 0)
    private var homeSwipeStart: (x: Float, y: Float)?
    private var homeSwipeTriggered = false

    init(frame frameRect: NSRect, device: MTLDevice?, mailbox: VideoFrameMailbox) {
        self.mailbox = mailbox
        let selectedDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: selectedDevice)
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true
        preferredFramesPerSecond = 120
        layer?.isOpaque = true
        wantsLayer = true
        clearColor = MTLClearColorMake(0.015, 0.015, 0.018, 1)
        delegate = self
        if let selectedDevice {
            ciContext = CIContext(mtlDevice: selectedDevice, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false,
            ])
            commandQueue = selectedDevice.makeCommandQueue()
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draw(in view: MTKView) {
        guard let snapshot = mailbox.snapshot(after: renderedGeneration) else { return }
        renderedGeneration = snapshot.generation
        let buffer = snapshot.buffer
        let orientation = snapshot.orientation
        guard
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var image = CIImage(cvPixelBuffer: buffer)
        switch orientation {
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.right)
        case 4: image = image.oriented(.left)
        default: break
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let target = CGRect(origin: .zero, size: drawableSize)
        let scale = min(target.width / extent.width, target.height / extent.height)
        let scaledSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        let tx = (target.width - scaledSize.width) / 2
        let ty = (target.height - scaledSize.height) / 2
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        ciContext.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Presentation telemetry must not enqueue another main-thread closure
        // for every frame. The counter is thread-safe and this draw callback is
        // already synchronized with MTKView's display cadence.
        onFramePresented?()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func mouseEntered(with event: NSEvent) { reportPointerActivity(event) }
    override func mouseMoved(with event: NSEvent) { reportPointerActivity(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = normalizedPoint(event)
        homeSwipeStart = point.y >= 0.965 ? point : nil
        homeSwipeTriggered = false
        // The physical Home-indicator area belongs to SpringBoard's system
        // gesture arena, not the foreground app. Reserve it here as well so the
        // app does not receive a stray touch before we decide this is Home.
        if homeSwipeStart != nil { return }
        onTouch?(0, point.x, point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = normalizedPoint(event)
        if !homeSwipeTriggered, let start = homeSwipeStart {
            let upward = start.y - point.y
            let horizontal = abs(point.x - start.x)
            // Mirror the iPhone Home-indicator gesture. IOHID injection does not
            // always enter SpringBoard's system-gesture arena, so a deliberate
            // upward swipe that begins on the bottom indicator is promoted to
            // the same Home action. Keep the start zone narrow so ordinary app
            // scrolling near the bottom remains untouched.
            if upward >= 0.105, horizontal <= 0.28 {
                homeSwipeTriggered = true
                onHomeGesture?()
            }
            return
        }
        onTouch?(1, point.x, point.y)
    }

    override func mouseUp(with event: NSEvent) {
        let point = normalizedPoint(event)
        if homeSwipeStart == nil {
            onTouch?(2, point.x, point.y)
        }
        homeSwipeStart = nil
        homeSwipeTriggered = false
    }

    override func scrollWheel(with event: NSEvent) {
        let point = normalizedPoint(event)
        let payload = makeScrollPayload(
            phase: Self.phaseCode(event.phase),
            momentumPhase: Self.phaseCode(event.momentumPhase),
            precise: event.hasPreciseScrollingDeltas,
            deltaX: Float(event.scrollingDeltaX),
            deltaY: Float(event.scrollingDeltaY),
            x: point.x,
            y: point.y,
            timestampNanos: UInt64(event.timestamp * 1_000_000_000)
        )
        onScroll?(payload)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            let mapping: [String: UInt8] = ["a": 10, "c": 11, "v": 12, "x": 13, "z": 14]
            if let code = mapping[chars] { onKey?(code); return }
        }
        switch event.keyCode {
        case 36, 76: onKey?(1)
        case 51, 117: onKey?(2)
        case 48: onKey?(3)
        case 53: onKey?(4)
        case 123: onKey?(5)
        case 124: onKey?(6)
        case 126: onKey?(7)
        case 125: onKey?(8)
        default:
            interpretKeyEvents([event])
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): onKey?(1)
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)): onKey?(2)
        case #selector(insertTab(_:)): onKey?(3)
        case #selector(cancelOperation(_:)): onKey?(4)
        case #selector(moveLeft(_:)): onKey?(5)
        case #selector(moveRight(_:)): onKey?(6)
        case #selector(moveUp(_:)): onKey?(7)
        case #selector(moveDown(_:)): onKey?(8)
        default: break
        }
    }

    private func normalizedPoint(_ event: NSEvent) -> (x: Float, y: Float) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = mailbox.geometry()
        let width = geometry.width
        let height = geometry.height
        let orientation = geometry.orientation
        let uprightWidth = (orientation == 3 || orientation == 4) ? height : width
        let uprightHeight = (orientation == 3 || orientation == 4) ? width : height
        let sourceAspect = CGFloat(uprightWidth) / CGFloat(max(uprightHeight, 1))
        let viewAspect = bounds.width / max(bounds.height, 1)
        let contentRect: CGRect
        if viewAspect > sourceAspect {
            let contentWidth = bounds.height * sourceAspect
            contentRect = CGRect(
                x: (bounds.width - contentWidth) * 0.5,
                y: 0,
                width: contentWidth,
                height: bounds.height
            )
        } else {
            let contentHeight = bounds.width / sourceAspect
            contentRect = CGRect(
                x: 0,
                y: (bounds.height - contentHeight) * 0.5,
                width: bounds.width,
                height: contentHeight
            )
        }
        let u = Float(min(max((point.x - contentRect.minX) / max(contentRect.width, 1), 0), 1))
        let v = Float(min(max(1 - (point.y - contentRect.minY) / max(contentRect.height, 1), 0), 1))
        return (u, v)
    }

    private func reportPointerActivity(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nearTop = point.y >= bounds.maxY - 72
        let nearRight = point.x >= bounds.maxX - 72
        if nearTop || nearRight {
            onPointerActivity?()
        }
    }

    private static func phaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 3 }
        if phase.contains(.cancelled) { return 4 }
        if phase.contains(.mayBegin) { return 5 }
        return 0
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value: String
        if let attributed = string as? NSAttributedString {
            value = attributed.string
        } else {
            value = String(describing: string)
        }
        marked = NSMutableAttributedString()
        selection = NSRange(location: 0, length: 0)
        onText?(value)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            marked = NSMutableAttributedString(attributedString: attributed)
        } else {
            marked = NSMutableAttributedString(string: String(describing: string))
        }
        selection = selectedRange
    }

    func unmarkText() {
        marked = NSMutableAttributedString()
        selection = NSRange(location: 0, length: 0)
    }

    func selectedRange() -> NSRange { selection }

    func markedRange() -> NSRange {
        marked.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.length)
    }

    func hasMarkedText() -> Bool { marked.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
        actualRange?.pointee = range
        return marked.attributedSubstring(from: range)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment, .textAlternatives]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        let local = NSRect(x: bounds.midX, y: bounds.maxY - 8, width: 1, height: 22)
        let windowRect = convert(local, to: nil)
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func conversationIdentifier() -> Int { Int(bitPattern: ObjectIdentifier(self)) }

    func draw(_: NSRect, forCharacterRange: NSRange, actualRange: NSRangePointer?) {}

    func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat { 0 }

    func baselineDeltaForCharacter(at index: Int) -> CGFloat { 0 }

    func windowLevel() -> Int { Int(window?.level.rawValue ?? 0) }
}
