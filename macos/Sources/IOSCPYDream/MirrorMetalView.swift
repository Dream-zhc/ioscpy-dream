import AppKit
import CoreImage
import CoreVideo
import MetalKit

@MainActor
final class MirrorMetalView: MTKView, MTKViewDelegate, @preconcurrency NSTextInputClient {
    var onTouch: ((UInt8, Float, Float) -> Void)?
    var onScroll: ((Data) -> Void)?
    var onText: ((String) -> Void)?
    var onKey: ((UInt8) -> Void)?
    var onFramePresented: (() -> Void)?
    var onPointerActivity: (() -> Void)?

    private let frameLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestOrientation = 1
    private var ciContext: CIContext!
    private var commandQueue: MTLCommandQueue!
    private var colorSpace = CGColorSpaceCreateDeviceRGB()
    private var marked = NSMutableAttributedString()
    private var selection = NSRange(location: 0, length: 0)

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let selectedDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: selectedDevice)
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = true
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

    func update(pixelBuffer: CVPixelBuffer, orientation: Int) {
        frameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestOrientation = orientation
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.draw() }
    }

    func draw(in view: MTKView) {
        frameLock.lock()
        let buffer = latestPixelBuffer
        let orientation = latestOrientation
        frameLock.unlock()
        guard let buffer,
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
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.onFramePresented?() }
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onPointerActivity?()
        let point = normalizedPoint(event)
        onTouch?(0, point.x, point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        onPointerActivity?()
        let point = normalizedPoint(event)
        onTouch?(1, point.x, point.y)
    }

    override func mouseUp(with event: NSEvent) {
        onPointerActivity?()
        let point = normalizedPoint(event)
        onTouch?(2, point.x, point.y)
    }

    override func scrollWheel(with event: NSEvent) {
        onPointerActivity?()
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
        onPointerActivity?()
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
        let u = Float(min(max(point.x / max(bounds.width, 1), 0), 1))
        let v = Float(min(max(1 - point.y / max(bounds.height, 1), 0), 1))
        frameLock.lock()
        let orientation = latestOrientation
        frameLock.unlock()
        switch orientation {
        case 2: return (1 - u, 1 - v)
        case 3: return (v, 1 - u)
        case 4: return (1 - v, u)
        default: return (u, v)
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
