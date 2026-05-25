# Input API

This document defines semantic input types and mapping responsibilities.

## Principle

Platform input must be normalized into semantic events before protocol encoding.

This keeps:
- GameController handling independent from wire format
- tests deterministic
- Sunshine/Apollo quirks isolated in encoders

## Semantic Events

```swift
public enum InputEvent: Sendable {
    case mouse(MouseEvent)
    case keyboard(KeyboardEvent)
    case touch(TouchEvent)
    case pen(PenEvent)
    case controller(ControllerEvent)
}
```

## Dispatch API

The runtime now separates semantic input generation from packet transport:

```swift
public protocol InputPacketTransport: Sendable {
    func send(_ packet: Data, channelID: UInt8, reliable: Bool) async throws
}

public protocol InputSending: Sendable {
    func send(_ event: InputEvent) async throws
}

public protocol InputFlushing: Sendable {
    func flushPendingInput() async throws
}

public protocol InputMetricsReporting: Sendable {
    func snapshotInputMetrics() async -> InputSenderMetrics
}

public actor InputEventDispatchQueue {
    public init(onFailure: @escaping FailureHandler = { _ in })

    public func enqueue(
        _ event: InputEvent,
        sender: any InputSending,
        sequence: UInt64,
        generation: UInt64
    )

    public func clear(generation: UInt64)
    public func waitUntilIdle() async
}

public actor InputSender: InputSending, InputFlushing, InputMetricsReporting {
    public init(
        encoder: any InputEncoder = BinaryInputEncoder(),
        context: InputEncodingContext,
        transport: any InputPacketTransport,
        configuration: InputSenderConfiguration = .init()
    )

    public func flushPendingMouseMotion() async throws
}
```

Apps attach an `InputSender` to `MoonlightSession` and continue working with semantic `InputEvent` values rather than binary packets.

`MoonlightSession` conforms to `InputSending`, so UI code can send directly to the session or route through `InputEventDispatchQueue`.

`InputEventDispatchQueue` is the app-facing helper for high-frequency UI input. It preserves caller-provided sequence order, drops stale generations after session changes, coalesces queued mouse motion before button/key events, and reports send failures through the configured failure handler. Use a new generation when replacing the active session or clearing capture/focus state.

`InputSender` also conforms to `InputFlushing`, so app code can call `MoonlightSession.flushPendingInput()` without retaining the concrete sender. This is the preferred integration-level API for focus changes, capture-mode transitions, and controlled teardown.

`InputEncodingContext` carries the host compatibility profile and stream viewport used for absolute input reference coordinates. Runtime-created senders derive it from `MoonlightHost.compatibilityProfile` and `NegotiatedSession.videoFormat`; app-created senders should do the same instead of hardcoding Sunshine defaults.

Mouse motion delivery is configurable:

```swift
public enum MouseMotionDeliveryPolicy: Sendable, Equatable {
    case coalesced(interval: Duration)
    case immediate
}

public struct InputSenderConfiguration: Sendable, Equatable {
    public var mouseMotionDeliveryPolicy: MouseMotionDeliveryPolicy
}

public struct InputMouseMotionAccumulator: Sendable, Equatable {
    public mutating func consume(deltaX: Double, deltaY: Double) -> [MouseEvent]
    public mutating func reset()
}
```

The default policy coalesces mouse motion for 1 ms, matching Moonlight's latency-reducing batching strategy for high-frequency pointer motion. Interactive video surfaces should keep that default unless measured queue latency shows the batching delay is the bottleneck; `.immediate` is useful as a diagnostic or for unusually sparse pointer sources. Call `flushPendingMouseMotion()` before deterministic assertions, teardown, capture-mode transitions, or any app lifecycle step that must guarantee the newest pointer position has reached the input transport.

If an app adds its own ordered UI-event queue before `MoonlightSession.send(_:)`, it must preserve key/button ordering and must not clamp accumulated relative mouse movement into a single `Int16` event. Prefer `InputEventDispatchQueue`; otherwise split oversized coalesced relative deltas into multiple `.relativeMove` events, or let `InputSender` perform the coalescing directly.

Relative pointer sources that expose fractional deltas should accumulate those fractions before creating integer Moonlight relative-move packets. App integrations can use `InputMouseMotionAccumulator` for captured macOS mouse input so slow movement is not rounded to zero per event.

`InputMetricsReporting` exposes packet count, queue latency, and transport-send latency from the sender. `MoonlightSession` mirrors those values into `SessionMetricsSnapshot` after `send(_:)`, `flushPendingInput()`, and best-effort stop-time flushing.

## Mouse

```swift
public enum MouseEvent: Sendable {
    case relativeMove(dx: Int16, dy: Int16)
    case absoluteMove(x: Double, y: Double)
    case button(button: MouseButton, state: ButtonState)
    case verticalScroll(delta: Int16)
    case horizontalScroll(delta: Int16)
}
```

Normalized coordinate rules:
- absolute mouse coordinates use unit space `0...1`
- encoder maps unit coordinates into the negotiated stream viewport reference plane before packet encoding
- Sunshine/Apollo still apply host-side touch-port transforms after receiving the packet
- app/UI code must not perform host-specific coordinate correction
- diagnostics and tests can use `HostInputCoordinateOracle` to model the observed Sunshine/Apollo host transform without changing packet bytes sent by apps

## Keyboard

```swift
public struct KeyCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16

    public static let space: KeyCode
    public static let enter: KeyCode
    public static let escape: KeyCode
    public static let leftArrow: KeyCode
    public static let a: KeyCode
    public static let leftShift: KeyCode
    public static let rightShift: KeyCode
}

public enum KeyboardEvent: Sendable {
    case keyDown(KeyCode, modifiers: KeyModifiers = [])
    case keyUp(KeyCode, modifiers: KeyModifiers = [])
    case text(String)
}
```

Rules:
- semantic key codes must be layout-independent
- semantic key codes use Moonlight/Win32 virtual-key values behind Swift constants
- text input is separate from physical key events
- shortcut synthesis belongs in the encoder layer when required by host behavior

## Touch

```swift
public struct TouchContact: Sendable {
    public var id: Int
    public var phase: TouchPhase
    public var x: Double
    public var y: Double
    public var pressure: Double?
    public var majorRadius: Double?
    public var minorRadius: Double?
    public var rotation: Double?
}

public struct TouchEvent: Sendable {
    public var contacts: [TouchContact]
}
```

Rules:
- touch coordinates use unit space `0...1`
- pressure is normalized where available
- encoder decides how unsupported fields are clamped or omitted
- Sunshine/Apollo touch-port differences are host-side transforms; app code should not pre-transform touch coordinates for a host profile

## Controllers

```swift
public struct ControllerID: Hashable, Sendable {
    public var rawValue: Int
}

public enum ControllerKind: Sendable {
    case xbox
    case dualSense
    case dualShock
    case extendedGamepad
    case unknown
}

public enum ControllerEvent: Sendable {
    case connected(ControllerDescriptor)
    case disconnected(ControllerID)
    case stateChanged(ControllerState)
    case battery(ControllerBattery)
    case motion(ControllerMotion)
    case touchpad(ControllerTouchpadEvent)
}
```

```swift
public struct ControllerDescriptor: Sendable {
    public var id: ControllerID
    public var kind: ControllerKind
    public var supportsRumble: Bool
    public var supportsTriggerRumble: Bool
    public var supportsMotion: Bool
    public var supportsTouchpad: Bool
}

public struct ControllerState: Sendable {
    public var id: ControllerID
    public var buttons: ControllerButtons
    public var leftStick: SIMD2<Float>
    public var rightStick: SIMD2<Float>
    public var leftTrigger: Float
    public var rightTrigger: Float
}
```

## Mapping Policy

Required in v1:
- Xbox controllers via `GameController`
- DualSense controllers via `GameController`
- a stable internal canonical layout

Rules:
- normalize all controllers into one canonical state model
- vendor-specific details stay in adapters, not encoders
- wire encoder handles host packet layout
- unsupported features may be dropped, but must be surfaced in capability reporting

## Controller Sources

The runtime input layer now includes a source boundary for physical controllers:

```swift
public protocol ControllerSource: Sendable {
    var events: AsyncStream<ControllerEvent> { get }
    func start() async
    func stop() async
}
```

Implemented runtime pieces:
- `PollingControllerSource`
- `ControllerSessionBridge`
- `GameControllerSnapshotProvider`

`ControllerSessionBridge` forwards normalized controller events into `MoonlightSession.send(.controller(...))`.

Current implementation notes:
- the Apple path is built around `GameController`
- the default runtime source currently polls controller snapshots rather than relying on connection callbacks
- connected, disconnected, and state-changed events are implemented
- `GameControllerSnapshotProvider` maps Xbox/DualSense profile identity, options/home/share/touchpad buttons, battery state, and motion samples when Apple exposes them
- battery, motion, and touchpad source emission are covered at the source boundary
- host feedback commands for rumble, trigger rumble, motion-report requests, LEDs, and adaptive triggers are surfaced as typed `SessionEvent.controllerFeedback` effects
- `GameControllerFeedbackSink` applies handle rumble, trigger rumble, RGB LED changes, and manual motion-sensor activation when `GameController` exposes those device features
- adaptive-trigger feedback is currently surfaced as typed data; the built-in `GameControllerFeedbackSink` only clears DualSense adaptive trigger mode when the host sends an explicit off request
- full adaptive-trigger payload mapping and live Xbox/DualSense device validation still need production tests

```swift
public struct ControllerFeedback: Sendable, Equatable {
    public var controllerID: Int
    public var supportsRumble: Bool
    public var effect: ControllerFeedbackEffect
}

public protocol ControllerFeedbackSink: Sendable {
    func apply(_ feedback: ControllerFeedback) async throws
}
```

## Usage

```swift
try await session.send(.controller(.connected(descriptor)))
try await session.send(.controller(.stateChanged(state)))
await session.attachControllerFeedbackSink(GameControllerFeedbackSink())
```

## DX Constraints

- app code should not manually build binary controller packets
- app code should not care whether the source device is Xbox or DualSense after normalization
