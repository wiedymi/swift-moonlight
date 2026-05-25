#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftMoonlightTestAppSupport
import SwiftUI

@MainActor
struct MetalSurfaceView: NSViewRepresentable {
    let device: MTLDevice?
    let streamDimensions: CGSize?
    let mouseMode: TestAppMouseMode
    let hideLocalCursor: Bool
    let onLayerReady: (CAMetalLayer) -> Void
    let onSurfaceSizeChanged: (CGSize) -> Void
    let onInput: (InputEvent) -> Void
    let onFocusChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MetalContainerView {
        let view = MetalContainerView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: MetalContainerView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: MetalContainerView) {
        view.metalLayer.device = device
        // The renderer owns pixel format/colorspace after prepare(). Resetting
        // them from SwiftUI updates can mismatch HDR pipelines and drawables.
        view.streamDimensions = streamDimensions
        view.mouseMode = mouseMode
        view.hideLocalCursor = hideLocalCursor
        view.onSurfaceSizeChanged = onSurfaceSizeChanged
        view.onInput = onInput
        view.onFocusChanged = onFocusChanged
        onLayerReady(view.metalLayer)
    }
}

@MainActor
final class MetalContainerView: NSView {
    let metalLayer = CAMetalLayer()

    var streamDimensions: CGSize?
    var mouseMode: TestAppMouseMode = .captured {
        didSet {
            guard oldValue != mouseMode else { return }
            reconcilePointerMode()
        }
    }
    var hideLocalCursor = false {
        didSet {
            guard oldValue != hideLocalCursor else { return }
            updateCursorVisibility()
        }
    }
    var onInput: ((InputEvent) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onSurfaceSizeChanged: ((CGSize) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var inputState = TestAppSurfaceInputState()
    private var isHovering = false
    private var isMouseCaptured = false
    private var isCursorHidden = false
    private var lastAbsoluteMouseLocation: CGPoint?
    private var lastReportedDrawableSize: CGSize?
    private var relativeMouseAccumulator = InputMouseMotionAccumulator()

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.framebufferOnly = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if isMouseCaptured {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if isCursorHidden {
            NSCursor.unhide()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateMetalLayerGeometry()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            releaseTrackedInput()
            disableMouseCapture()
            setCursorHidden(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        updateMetalLayerGeometry()
        lastAbsoluteMouseLocation = nil
        relativeMouseAccumulator.reset()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseMoved,
                .mouseEnteredAndExited,
                .enabledDuringMouseDrag,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func becomeFirstResponder() -> Bool {
        onFocusChanged?(true)
        reconcilePointerMode()
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseTrackedInput()
        disableMouseCapture()
        lastAbsoluteMouseLocation = nil
        onFocusChanged?(false)
        updateCursorVisibility()
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateCursorVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        lastAbsoluteMouseLocation = nil
        updateCursorVisibility()
    }

    override func mouseDown(with event: NSEvent) {
        requestInputFocus()
        if mouseMode == .direct {
            dispatchAbsolutePointerLocation(for: event, force: true)
        }
        dispatch(inputState.pressMouseButton(.left, buttonNumber: 0))
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputFocused || inputState.isMouseButtonPressed(0) else { return }
        if mouseMode == .direct {
            dispatchAbsolutePointerLocation(for: event)
        }
        dispatch(inputState.releaseMouseButton(.left, buttonNumber: 0))
    }

    override func rightMouseDown(with event: NSEvent) {
        requestInputFocus()
        if mouseMode == .direct {
            dispatchAbsolutePointerLocation(for: event, force: true)
        }
        dispatch(inputState.pressMouseButton(.right, buttonNumber: 1))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isInputFocused || inputState.isMouseButtonPressed(1) else { return }
        if mouseMode == .direct {
            dispatchAbsolutePointerLocation(for: event)
        }
        dispatch(inputState.releaseMouseButton(.right, buttonNumber: 1))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let button = TestAppSurfaceInputMapper.mouseButton(for: event.buttonNumber) else { return }
        requestInputFocus()
        if mouseMode == .direct {
            dispatchAbsolutePointerLocation(for: event, force: true)
        }
        dispatch(inputState.pressMouseButton(button, buttonNumber: event.buttonNumber))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard (isInputFocused || inputState.isMouseButtonPressed(event.buttonNumber)),
              let button = TestAppSurfaceInputMapper.mouseButton(for: event.buttonNumber)
        else { return }
        if mouseMode == .direct {
            dispatchAbsolutePointerLocation(for: event)
        }
        dispatch(inputState.releaseMouseButton(button, buttonNumber: event.buttonNumber))
    }

    override func mouseMoved(with event: NSEvent) {
        handlePointerMotion(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        handlePointerMotion(for: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handlePointerMotion(for: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handlePointerMotion(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInputFocused else { return }

        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 10 : 1
        if let horizontalDelta = Self.scrollDelta(from: event.scrollingDeltaX * scale) {
            dispatch(.mouse(.horizontalScroll(delta: horizontalDelta)))
        }
        if let verticalDelta = Self.scrollDelta(from: event.scrollingDeltaY * scale) {
            dispatch(.mouse(.verticalScroll(delta: verticalDelta)))
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isInputFocused,
              TestAppSurfaceInputMapper.keyCode(for: event.keyCode) != nil
        else {
            super.keyDown(with: event)
            return
        }

        dispatch(
            inputState.keyDown(
                macKeyCode: event.keyCode,
                isRepeat: event.isARepeat,
                modifierFlags: event.modifierFlags
            )
        )
    }

    override func keyUp(with event: NSEvent) {
        guard isInputFocused,
              TestAppSurfaceInputMapper.keyCode(for: event.keyCode) != nil
        else {
            super.keyUp(with: event)
            return
        }

        dispatch(inputState.keyUp(macKeyCode: event.keyCode, modifierFlags: event.modifierFlags))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isInputFocused else {
            return
        }

        dispatch(inputState.modifierChanged(macKeyCode: event.keyCode, modifierFlags: event.modifierFlags))
    }

    private var isInputFocused: Bool {
        window?.firstResponder === self
    }

    private func requestInputFocus() {
        window?.makeFirstResponder(self)
    }

    private func dispatch(_ event: InputEvent) {
        onInput?(event)
    }

    private func dispatch(_ event: InputEvent?) {
        guard let event else { return }
        dispatch(event)
    }

    private func handlePointerMotion(for event: NSEvent) {
        switch mouseMode {
        case .direct:
            dispatchAbsolutePointerLocation(for: event)
        case .captured:
            dispatchRelativePointerMotion(for: event)
        }
    }

    private func dispatchAbsolutePointerLocation(for event: NSEvent, force: Bool = false) {
        guard force || isInputFocused else { return }
        let videoRect = videoContentRect()
        guard videoRect.width > 0, videoRect.height > 0 else { return }

        let point = convert(event.locationInWindow, from: nil)
        let x = point.x - bounds.minX
        let y = point.y - bounds.minY

        let confinedX = min(max(x, videoRect.minX), videoRect.maxX) - videoRect.minX
        let confinedY = min(max(y, videoRect.minY), videoRect.maxY) - videoRect.minY
        let location = CGPoint(x: confinedX, y: confinedY)
        if !force, lastAbsoluteMouseLocation == location {
            return
        }

        lastAbsoluteMouseLocation = location

        let normalizedX = min(max(location.x / videoRect.width, 0), 1)
        let normalizedY = min(max(location.y / videoRect.height, 0), 1)
        dispatch(.mouse(.absoluteMove(x: normalizedX, y: normalizedY)))
    }

    private func dispatchRelativePointerMotion(for event: NSEvent) {
        guard isMouseCaptured else { return }

        let delta = TestAppSurfaceInputMapper.relativePointerDelta(
            appKitDeltaX: event.deltaX,
            appKitDeltaY: event.deltaY
        )
        let mouseEvents = relativeMouseAccumulator.consume(
            deltaX: delta.x,
            deltaY: delta.y
        )
        for mouseEvent in mouseEvents {
            dispatch(.mouse(mouseEvent))
        }
    }

    private func videoContentRect() -> CGRect {
        // The Metal target currently presents into the full layer. Input must
        // use the same rectangle, otherwise Apollo virtual-display sessions
        // drift when the stream window is not exactly the negotiated aspect.
        bounds
    }

    private func updateMetalLayerGeometry() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale

        let drawableSize = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
        if lastReportedDrawableSize != drawableSize {
            lastReportedDrawableSize = drawableSize
            onSurfaceSizeChanged?(drawableSize)
        }
    }

    private func reconcilePointerMode() {
        if mouseMode == .captured && isInputFocused {
            enableMouseCapture()
        } else {
            disableMouseCapture()
        }
        updateCursorVisibility()
    }

    private func enableMouseCapture() {
        guard !isMouseCaptured else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        isMouseCaptured = true
        updateCursorVisibility()
    }

    private func disableMouseCapture() {
        guard isMouseCaptured else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        isMouseCaptured = false
        relativeMouseAccumulator.reset()
        updateCursorVisibility()
    }

    private func updateCursorVisibility() {
        let shouldHideCursor = hideLocalCursor && (isMouseCaptured || (mouseMode == .direct && isHovering))
        setCursorHidden(shouldHideCursor)
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != isCursorHidden else { return }
        if hidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }
        isCursorHidden = hidden
    }

    private func releaseTrackedInput() {
        for event in inputState.releaseTrackedInput() {
            dispatch(event)
        }
    }

    private static func scrollDelta(from value: CGFloat) -> Int16? {
        let rounded = Int(value.rounded())
        guard rounded != 0 else { return nil }
        return Int16(clamping: rounded)
    }
}
#endif
