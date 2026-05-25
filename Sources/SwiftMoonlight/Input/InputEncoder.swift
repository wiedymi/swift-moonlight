import CoreGraphics
import Foundation

public struct InputEncodingContext: Sendable {
    public var hostProfile: HostCompatibilityProfile
    public var streamViewport: CGSize
    public var absoluteReferenceWidth: Int16
    public var absoluteReferenceHeight: Int16

    public var hostKind: HostKind {
        get { hostProfile.kind }
        set {
            hostProfile = .for(newValue)
        }
    }

    public init(
        hostKind: HostKind,
        absoluteReferenceWidth: Int16 = .max,
        absoluteReferenceHeight: Int16 = .max
    ) {
        self.hostProfile = .for(hostKind)
        self.streamViewport = CGSize(
            width: CGFloat(max(Int(absoluteReferenceWidth), 1)),
            height: CGFloat(max(Int(absoluteReferenceHeight), 1))
        )
        self.absoluteReferenceWidth = absoluteReferenceWidth
        self.absoluteReferenceHeight = absoluteReferenceHeight
    }

    public init(
        hostProfile: HostCompatibilityProfile,
        streamViewport: CGSize
    ) {
        self.hostProfile = hostProfile
        self.streamViewport = streamViewport
        self.absoluteReferenceWidth = Self.referenceDimension(from: streamViewport.width)
        self.absoluteReferenceHeight = Self.referenceDimension(from: streamViewport.height)
    }

    public init(
        host: MoonlightHost,
        negotiatedSession: NegotiatedSession
    ) {
        self.init(
            hostProfile: host.compatibilityProfile,
            streamViewport: negotiatedSession.videoFormat?.dimensions ?? CGSize(
                width: CGFloat(Int16.max),
                height: CGFloat(Int16.max)
            )
        )
    }

    private static func referenceDimension(from value: CGFloat) -> Int16 {
        guard value.isFinite, value > 0 else {
            return .max
        }
        return Int16(clamping: Int(value.rounded(.down)))
    }
}

public protocol InputEncoder: Sendable {
    func encode(_ event: InputEvent, context: InputEncodingContext) throws -> [EncodedInputPacket]
}

public struct BinaryInputEncoder: InputEncoder {
    public init() {}

    public func encode(_ event: InputEvent, context: InputEncodingContext) throws -> [EncodedInputPacket] {
        switch event {
        case let .mouse(mouseEvent):
            return [try encodeMouse(mouseEvent, context: context)]
        case let .keyboard(keyboardEvent):
            return [try encodeKeyboard(keyboardEvent, context: context)]
        case let .touch(touchEvent):
            return encodeTouch(touchEvent, context: context)
        case let .pen(penEvent):
            return [try encodePen(penEvent, context: context)]
        case let .controller(controllerEvent):
            return try encodeController(controllerEvent, context: context)
        }
    }

    private func encodeMouse(_ event: MouseEvent, context: InputEncodingContext) throws -> EncodedInputPacket {
        let payload: Data
        switch event {
        case let .relativeMove(dx, dy):
            payload = inputHeader(size: 8, magic: 0x00000007)
                + be16(dx)
                + be16(dy)

        case let .button(button, state):
            let buttonCode: UInt8
            switch button {
            case .left: buttonCode = 0x01
            case .middle: buttonCode = 0x02
            case .right: buttonCode = 0x03
            case .x1: buttonCode = 0x04
            case .x2: buttonCode = 0x05
            }

            let magic: UInt32 = state == .pressed ? 0x00000008 : 0x00000009
            payload = inputHeader(size: 5, magic: magic)
                + Data([buttonCode])

        case let .absoluteMove(x, y):
            let refWidth = max(context.absoluteReferenceWidth, 1)
            let refHeight = max(context.absoluteReferenceHeight, 1)
            let normalizedX = normalizeCoordinate(x, reference: refWidth)
            let normalizedY = normalizeCoordinate(y, reference: refHeight)

            payload = inputHeader(size: 12, magic: 0x00000005)
                + be16(normalizedX)
                + be16(normalizedY)
                + be16(0)
                + be16(max(refWidth - 1, 0))
                + be16(max(refHeight - 1, 0))

        case let .verticalScroll(delta):
            payload = inputHeader(size: 10, magic: 0x0000000A)
                + be16(delta)
                + be16(delta)
                + be16(0)

        case let .horizontalScroll(delta):
            guard context.hostKind == .sunshine || context.hostKind == .apollo else {
                throw MoonlightError(.unsupportedOperation, message: "Horizontal scroll is only supported for Sunshine-compatible hosts")
            }

            payload = inputHeader(size: 6, magic: 0x55000001)
                + be16(delta)
        }

        return EncodedInputPacket(payload: payload, channelID: ControlChannelID.mouse, reliable: true)
    }

    private func encodeKeyboard(_ event: KeyboardEvent, context: InputEncodingContext) throws -> EncodedInputPacket {
        let flags: UInt8 = context.hostKind == .sunshine || context.hostKind == .apollo ? 0 : 0
        let payload: Data
        let channelID: UInt8

        switch event {
        case let .keyDown(code, modifiers):
            payload = inputHeader(size: 10, magic: 0x00000003)
                + Data([flags])
                + le16(Int16(bitPattern: code.rawValue))
                + Data([modifiers.rawValue])
                + le16(0)
            channelID = ControlChannelID.keyboard

        case let .keyUp(code, modifiers):
            payload = inputHeader(size: 10, magic: 0x00000004)
                + Data([flags])
                + le16(Int16(bitPattern: code.rawValue))
                + Data([modifiers.rawValue])
                + le16(0)
            channelID = ControlChannelID.keyboard

        case let .text(value):
            let bytes = Array(value.utf8)
            guard !bytes.isEmpty, bytes.count <= 32 else {
                throw MoonlightError(.unsupportedOperation, message: "UTF-8 text payload must be between 1 and 32 bytes")
            }
            payload = inputHeader(size: UInt32(4 + bytes.count), magic: 0x00000017)
                + Data(bytes)
            channelID = ControlChannelID.utf8
        }

        return EncodedInputPacket(payload: payload, channelID: channelID, reliable: true)
    }

    private func encodeTouch(_ event: TouchEvent, context: InputEncodingContext) -> [EncodedInputPacket] {
        event.contacts.map { contact in
            let coordinate = normalizedTouchCoordinate(x: contact.x, y: contact.y, context: context)
            return EncodedInputPacket(
                payload: inputHeader(size: 32, magic: 0x55000002)
                + Data([touchPhaseCode(contact.phase), 0x00])
                + le16(contact.rotation)
                + le32(UInt32(clamping: contact.id))
                + netfloat(coordinate.x)
                + netfloat(coordinate.y)
                + netfloat(clampUnit(contact.pressure))
                + netfloat(clampUnit(contact.contactAreaMajor))
                + netfloat(clampUnit(contact.contactAreaMinor)),
                channelID: ControlChannelID.touch,
                reliable: !touchPhaseIsBatchable(contact.phase)
            )
        }
    }

    private func encodePen(_ event: PenEvent, context: InputEncodingContext) throws -> EncodedInputPacket {
        guard context.hostKind == .sunshine || context.hostKind == .apollo else {
            throw MoonlightError(.unsupportedOperation, message: "Pen input is only supported for Sunshine-compatible hosts")
        }

        let contact = event.contact
        let coordinate = normalizedTouchCoordinate(x: contact.x, y: contact.y, context: context)
        return EncodedInputPacket(
            payload: inputHeader(size: 32, magic: 0x55000003)
            + Data([touchPhaseCode(contact.phase), contact.toolType.rawValue, contact.buttons.rawValue, 0x00])
            + netfloat(coordinate.x)
            + netfloat(coordinate.y)
            + netfloat(clampUnit(contact.pressure))
            + le16(contact.rotation)
            + Data([contact.tilt, 0x00])
            + netfloat(clampUnit(contact.contactAreaMajor))
            + netfloat(clampUnit(contact.contactAreaMinor)),
            channelID: ControlChannelID.pen,
            reliable: !touchPhaseIsBatchable(contact.phase) || !contact.buttons.isEmpty
        )
    }

    private func encodeController(_ event: ControllerEvent, context: InputEncodingContext) throws -> [EncodedInputPacket] {
        switch event {
        case let .connected(descriptor):
            let controllerNumber = UInt8(clamping: descriptor.id.rawValue)
            let activeMask = Int16(bitPattern: 1 << min(max(descriptor.id.rawValue, 0), 15))

            let arrival = inputHeader(size: 12, magic: 0x55000004)
                + Data([controllerNumber, controllerTypeCode(descriptor.kind)])
                + le16(Int16(bitPattern: controllerCapabilities(descriptor)))
                + le32(controllerSupportedButtons(descriptor.supportedButtons))

            let fallback = multiControllerPacket(
                controllerNumber: Int16(controllerNumber),
                activeGamepadMask: activeMask,
                buttons: [],
                leftTrigger: 0,
                rightTrigger: 0,
                leftStick: .zero,
                rightStick: .zero
            )

            if context.hostKind == .sunshine || context.hostKind == .apollo {
                return [
                    EncodedInputPacket(
                        payload: arrival,
                        channelID: ControlChannelID.gamepadBase &+ controllerNumber,
                        reliable: true
                    ),
                    EncodedInputPacket(
                        payload: fallback,
                        channelID: ControlChannelID.gamepadBase &+ controllerNumber,
                        reliable: true
                    ),
                ]
            } else {
                return [
                    EncodedInputPacket(
                        payload: fallback,
                        channelID: ControlChannelID.gamepadBase &+ controllerNumber,
                        reliable: true
                    )
                ]
            }

        case let .stateChanged(state):
            let controllerChannelID = ControlChannelID.gamepadBase &+ UInt8(clamping: state.id.rawValue)
            return [EncodedInputPacket(
                payload: multiControllerPacket(
                    controllerNumber: Int16(clamping: state.id.rawValue),
                    activeGamepadMask: Int16(bitPattern: 1 << min(max(state.id.rawValue, 0), 15)),
                    buttons: state.buttons,
                    leftTrigger: encodeTrigger(state.leftTrigger),
                    rightTrigger: encodeTrigger(state.rightTrigger),
                    leftStick: state.leftStick,
                    rightStick: state.rightStick
                ),
                channelID: controllerChannelID,
                reliable: true
            )]

        case let .disconnected(id):
            let controllerChannelID = ControlChannelID.gamepadBase &+ UInt8(clamping: id.rawValue)
            return [EncodedInputPacket(
                payload: multiControllerPacket(
                    controllerNumber: Int16(clamping: id.rawValue),
                    activeGamepadMask: 0,
                    buttons: [],
                    leftTrigger: 0,
                    rightTrigger: 0,
                    leftStick: .zero,
                    rightStick: .zero
                ),
                channelID: controllerChannelID,
                reliable: true
            )]

        case let .battery(battery):
            let controllerChannelID = ControlChannelID.gamepadBase &+ UInt8(clamping: battery.id.rawValue)
            return [EncodedInputPacket(
                payload: inputHeader(size: 8, magic: 0x55000007)
                    + Data([UInt8(clamping: battery.id.rawValue), battery.state.rawValue, battery.percentage, 0x00]),
                channelID: controllerChannelID,
                reliable: true
            )]

        case let .motion(motion):
            let controllerChannelID = ControlChannelID.sensorBase &+ UInt8(clamping: motion.id.rawValue)
            let isZeroGyro = motion.motionType == .gyroscope && motion.x == 0 && motion.y == 0 && motion.z == 0
            return [EncodedInputPacket(
                payload: inputHeader(size: 20, magic: 0x55000006)
                    + Data([UInt8(clamping: motion.id.rawValue), motion.motionType.rawValue, 0x00, 0x00])
                    + netfloat(Double(motion.x))
                    + netfloat(Double(motion.y))
                    + netfloat(Double(motion.z)),
                channelID: controllerChannelID,
                reliable: isZeroGyro
            )]

        case let .touchpad(touchpad):
            let controllerChannelID = ControlChannelID.gamepadBase &+ UInt8(clamping: touchpad.id.rawValue)
            return [EncodedInputPacket(
                payload: inputHeader(size: 24, magic: 0x55000005)
                    + Data([UInt8(clamping: touchpad.id.rawValue), touchPhaseCode(touchpad.phase), 0x00, 0x00])
                    + le32(touchpad.pointerID)
                    + netfloat(touchpad.x)
                    + netfloat(touchpad.y)
                    + netfloat(touchpad.pressure),
                channelID: controllerChannelID,
                reliable: !touchPhaseIsBatchable(touchpad.phase)
            )]
        }
    }

    private func touchPhaseIsBatchable(_ phase: TouchPhase) -> Bool {
        switch phase {
        case .hovering, .moved:
            return true
        case .began, .ended, .cancelled, .hoverEnded, .cancelledAll:
            return false
        }
    }

    private func touchPhaseCode(_ phase: TouchPhase) -> UInt8 {
        switch phase {
        case .hovering: return 0x00
        case .began: return 0x01
        case .ended: return 0x02
        case .moved: return 0x03
        case .cancelled: return 0x04
        case .hoverEnded: return 0x06
        case .cancelledAll: return 0x07
        }
    }

    private func controllerTypeCode(_ kind: ControllerKind) -> UInt8 {
        switch kind {
        case .xbox: return 0x01
        case .dualSense, .dualShock: return 0x02
        case .extendedGamepad: return 0x00
        case .unknown: return 0x00
        }
    }

    private func controllerCapabilities(_ descriptor: ControllerDescriptor) -> UInt16 {
        var capabilities: UInt16 = 0x01
        if descriptor.supportsRumble { capabilities |= 0x02 }
        if descriptor.supportsTriggerRumble { capabilities |= 0x04 }
        if descriptor.supportsTouchpad { capabilities |= 0x08 }
        if descriptor.supportsMotion { capabilities |= 0x10 | 0x20 }
        if descriptor.supportsBatteryState { capabilities |= 0x40 }
        if descriptor.supportsRGBLED { capabilities |= 0x80 }
        return capabilities
    }

    private func controllerSupportedButtons(_ buttons: ControllerButtons) -> UInt32 {
        buttonFlags(buttons)
    }

    private func be16(_ value: Int16) -> Data {
        let bitPattern = UInt16(bitPattern: value)
        return Data([UInt8((bitPattern >> 8) & 0xFF), UInt8(bitPattern & 0xFF)])
    }

    private func le16(_ value: Int16) -> Data {
        let bitPattern = UInt16(bitPattern: value)
        return Data([UInt8(bitPattern & 0xFF), UInt8((bitPattern >> 8) & 0xFF)])
    }

    private func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    private func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private func inputHeader(size: UInt32, magic: UInt32) -> Data {
        be32(size) + le32(magic)
    }

    private func normalizeCoordinate(_ value: Double, reference: Int16) -> Int16 {
        let clamped = min(max(value, 0), 1)
        let maxValue = max(Int(reference), 0)
        let scaled = Int((Double(maxValue) * clamped).rounded(.down))
        return Int16(clamping: scaled)
    }

    private func normalizedTouchCoordinate(
        x: Double,
        y: Double,
        context: InputEncodingContext
    ) -> (x: Double, y: Double) {
        // Sunshine and Apollo apply different touch-port transforms after
        // receiving these packets. The client packet remains normalized to the
        // presented stream surface for both host families.
        switch context.hostKind {
        case .sunshine, .apollo, .unknown:
            return (clampUnit(x), clampUnit(y))
        }
    }

    private func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func encodeSignedAxis(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        let scaled = Int(Float(Int16.max) * clamped)
        return Int16(clamping: scaled)
    }

    private func encodeTrigger(_ value: Float) -> UInt8 {
        UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded(.down)))
    }

    private func netfloat(_ value: Double) -> Data {
        le32(Float(value).bitPattern)
    }

    private func buttonFlags(_ buttons: ControllerButtons) -> UInt32 {
        var value: UInt32 = 0
        if buttons.contains(.dpadUp) { value |= 0x0001 }
        if buttons.contains(.dpadDown) { value |= 0x0002 }
        if buttons.contains(.dpadLeft) { value |= 0x0004 }
        if buttons.contains(.dpadRight) { value |= 0x0008 }
        if buttons.contains(.start) { value |= 0x0010 }
        if buttons.contains(.back) { value |= 0x0020 }
        if buttons.contains(.leftStickPress) { value |= 0x0040 }
        if buttons.contains(.rightStickPress) { value |= 0x0080 }
        if buttons.contains(.leftShoulder) { value |= 0x0100 }
        if buttons.contains(.rightShoulder) { value |= 0x0200 }
        if buttons.contains(.guide) { value |= 0x0400 }
        if buttons.contains(.a) { value |= 0x1000 }
        if buttons.contains(.b) { value |= 0x2000 }
        if buttons.contains(.x) { value |= 0x4000 }
        if buttons.contains(.y) { value |= 0x8000 }
        if buttons.contains(.paddle1) { value |= 0x010000 }
        if buttons.contains(.paddle2) { value |= 0x020000 }
        if buttons.contains(.paddle3) { value |= 0x040000 }
        if buttons.contains(.paddle4) { value |= 0x080000 }
        if buttons.contains(.touchpad) { value |= 0x100000 }
        if buttons.contains(.misc) { value |= 0x200000 }
        return value
    }

    private func multiControllerPacket(
        controllerNumber: Int16,
        activeGamepadMask: Int16,
        buttons: ControllerButtons,
        leftTrigger: UInt8,
        rightTrigger: UInt8,
        leftStick: SIMD2<Float>,
        rightStick: SIMD2<Float>
    ) -> Data {
        let flags = buttonFlags(buttons)
        var data = inputHeader(size: 30, magic: 0x0000000C)
        data.append(le16(0x001A))
        data.append(le16(controllerNumber))
        data.append(le16(activeGamepadMask))
        data.append(le16(0x0014))
        data.append(le16(Int16(bitPattern: UInt16(truncatingIfNeeded: flags & 0xFFFF))))
        data.append(Data([leftTrigger, rightTrigger]))
        data.append(le16(encodeSignedAxis(leftStick.x)))
        data.append(le16(encodeSignedAxis(leftStick.y)))
        data.append(le16(encodeSignedAxis(rightStick.x)))
        data.append(le16(encodeSignedAxis(rightStick.y)))
        data.append(le16(0x009C))
        data.append(le16(Int16(bitPattern: UInt16(truncatingIfNeeded: (flags >> 16) & 0xFFFF))))
        data.append(le16(0x0055))
        return data
    }
}
