import Foundation

public enum ControlChannelID {
    public static let generic: UInt8 = 0x00
    public static let urgent: UInt8 = 0x01
    public static let keyboard: UInt8 = 0x02
    public static let mouse: UInt8 = 0x03
    public static let pen: UInt8 = 0x04
    public static let touch: UInt8 = 0x05
    public static let utf8: UInt8 = 0x06
    public static let gamepadBase: UInt8 = 0x10
    public static let sensorBase: UInt8 = 0x20
    public static let count: UInt8 = 0x30
}

public enum ControlPacketType: UInt16, Sendable, Equatable {
    case requestIDRFrame = 0x0302
    case termination = 0x0109
    case rumble = 0x010B
    case hdrMode = 0x010E
    case rumbleTriggers = 0x5500
    case setMotionEventState = 0x5501
    case setControllerLED = 0x5502
    case setAdaptiveTriggers = 0x5503
}

public struct ControlPacketEncoder: Sendable {
    public static let frameFECStatusPacketType: UInt16 = 0x5502

    public init() {}

    public func requestIDRFramePacket() -> Data {
        Data([0x02, 0x03, 0x00, 0x00])
    }

    public func frameFECStatusPayload(_ status: VideoFrameFECStatus) -> Data {
        var payload = Data()
        payload.appendBE(status.frameIndex)
        payload.appendBE(status.highestReceivedSequenceNumber)
        payload.appendBE(status.nextContiguousSequenceNumber)
        payload.appendBE(status.missingPacketsBeforeHighestReceived)
        payload.appendBE(status.totalDataPackets)
        payload.appendBE(status.totalParityPackets)
        payload.appendBE(status.receivedDataPackets)
        payload.appendBE(status.receivedParityPackets)
        payload.append(status.fecPercentage)
        payload.append(status.multiFecBlockIndex)
        payload.append(status.multiFecBlockCount)
        return payload
    }

    public func frameFECStatusPacket(_ status: VideoFrameFECStatus) -> Data {
        var packet = Data()
        packet.appendLE(Self.frameFECStatusPacketType)
        packet.append(frameFECStatusPayload(status))
        return packet
    }
}

public struct ControllerRumble: Sendable, Equatable {
    public var controllerNumber: UInt16
    public var lowFrequencyMotor: UInt16
    public var highFrequencyMotor: UInt16

    public init(controllerNumber: UInt16, lowFrequencyMotor: UInt16, highFrequencyMotor: UInt16) {
        self.controllerNumber = controllerNumber
        self.lowFrequencyMotor = lowFrequencyMotor
        self.highFrequencyMotor = highFrequencyMotor
    }
}

public struct ControllerTriggerRumble: Sendable, Equatable {
    public var controllerNumber: UInt16
    public var leftTriggerMotor: UInt16
    public var rightTriggerMotor: UInt16

    public init(controllerNumber: UInt16, leftTriggerMotor: UInt16, rightTriggerMotor: UInt16) {
        self.controllerNumber = controllerNumber
        self.leftTriggerMotor = leftTriggerMotor
        self.rightTriggerMotor = rightTriggerMotor
    }
}

public struct MotionEventStateRequest: Sendable, Equatable {
    public var controllerNumber: UInt16
    public var motionType: UInt8
    public var reportRateHz: UInt16

    public init(controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        self.controllerNumber = controllerNumber
        self.motionType = motionType
        self.reportRateHz = reportRateHz
    }
}

public struct ControllerLEDUpdate: Sendable, Equatable {
    public var controllerNumber: UInt16
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(controllerNumber: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
        self.controllerNumber = controllerNumber
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct AdaptiveTriggerUpdate: Sendable, Equatable {
    public static let effectPayloadSize = 10
    public static let rightTriggerFlag: UInt8 = 0x04
    public static let leftTriggerFlag: UInt8 = 0x08

    public var controllerNumber: UInt16
    public var eventFlags: UInt8
    public var leftTriggerType: UInt8
    public var rightTriggerType: UInt8
    public var leftPayload: [UInt8]
    public var rightPayload: [UInt8]

    public init(
        controllerNumber: UInt16,
        eventFlags: UInt8,
        leftTriggerType: UInt8,
        rightTriggerType: UInt8,
        leftPayload: [UInt8],
        rightPayload: [UInt8]
    ) {
        self.controllerNumber = controllerNumber
        self.eventFlags = eventFlags
        self.leftTriggerType = leftTriggerType
        self.rightTriggerType = rightTriggerType
        self.leftPayload = leftPayload
        self.rightPayload = rightPayload
    }
}

public struct RawChromaticityPoint: Sendable, Equatable {
    public var x: UInt16
    public var y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }
}

public struct HDRMetadata: Sendable, Equatable {
    public var displayPrimaries: [RawChromaticityPoint]
    public var whitePoint: RawChromaticityPoint
    public var maxDisplayLuminance: UInt16
    public var minDisplayLuminance: UInt16
    public var maxContentLightLevel: UInt16
    public var maxFrameAverageLightLevel: UInt16
    public var maxFullFrameLuminance: UInt16

    public init(
        displayPrimaries: [RawChromaticityPoint],
        whitePoint: RawChromaticityPoint,
        maxDisplayLuminance: UInt16,
        minDisplayLuminance: UInt16,
        maxContentLightLevel: UInt16,
        maxFrameAverageLightLevel: UInt16,
        maxFullFrameLuminance: UInt16
    ) {
        self.displayPrimaries = displayPrimaries
        self.whitePoint = whitePoint
        self.maxDisplayLuminance = maxDisplayLuminance
        self.minDisplayLuminance = minDisplayLuminance
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
        self.maxFullFrameLuminance = maxFullFrameLuminance
    }
}

public struct HDRModeUpdate: Sendable, Equatable {
    public var enabled: Bool
    public var metadata: HDRMetadata?

    public init(enabled: Bool, metadata: HDRMetadata?) {
        self.enabled = enabled
        self.metadata = metadata
    }
}

public enum ConnectionTerminationReason: Sendable, Equatable {
    case graceful
    case unexpectedEarly
    case protectedContent
    case frameConversion
    case hostCode(UInt32)
}

public struct ConnectionTermination: Sendable, Equatable {
    public var rawCode: UInt32
    public var reason: ConnectionTerminationReason

    public init(rawCode: UInt32, reason: ConnectionTerminationReason) {
        self.rawCode = rawCode
        self.reason = reason
    }
}

public enum ControlMessage: Sendable, Equatable {
    case rumble(ControllerRumble)
    case rumbleTriggers(ControllerTriggerRumble)
    case setMotionEventState(MotionEventStateRequest)
    case setControllerLED(ControllerLEDUpdate)
    case hdrModeChanged(HDRModeUpdate)
    case adaptiveTriggers(AdaptiveTriggerUpdate)
    case terminated(ConnectionTermination)
}

public struct ControlDecodingContext: Sendable, Equatable {
    public var hasReceivedVideoFrame: Bool

    public init(hasReceivedVideoFrame: Bool = false) {
        self.hasReceivedVideoFrame = hasReceivedVideoFrame
    }
}

public struct ControlMessageParser: Sendable {
    public init() {}

    public func parse(packet: Data, context: ControlDecodingContext = .init()) throws -> ControlMessage? {
        guard packet.count >= 2 else {
            throw MoonlightError(.invalidControlMessage, message: "Control packet is too short")
        }

        let type = readUInt16LE(from: packet, at: 0)
        let payload = packet.dropFirst(2)

        guard let packetType = ControlPacketType(rawValue: type) else {
            return nil
        }

        switch packetType {
        case .requestIDRFrame:
            return nil
        case .rumble:
            guard payload.count >= 10 else {
                throw MoonlightError(.invalidControlMessage, message: "Rumble packet is too short")
            }

            return .rumble(.init(
                controllerNumber: readUInt16LE(from: payload, at: 4),
                lowFrequencyMotor: readUInt16LE(from: payload, at: 6),
                highFrequencyMotor: readUInt16LE(from: payload, at: 8)
            ))

        case .rumbleTriggers:
            guard payload.count >= 6 else {
                throw MoonlightError(.invalidControlMessage, message: "Trigger rumble packet is too short")
            }

            return .rumbleTriggers(.init(
                controllerNumber: readUInt16LE(from: payload, at: 0),
                leftTriggerMotor: readUInt16LE(from: payload, at: 2),
                rightTriggerMotor: readUInt16LE(from: payload, at: 4)
            ))

        case .setMotionEventState:
            guard payload.count >= 5 else {
                throw MoonlightError(.invalidControlMessage, message: "Motion event state packet is too short")
            }

            return .setMotionEventState(.init(
                controllerNumber: readUInt16LE(from: payload, at: 0),
                motionType: readUInt8(from: payload, at: 4),
                reportRateHz: readUInt16LE(from: payload, at: 2)
            ))

        case .setControllerLED:
            guard payload.count >= 5 else {
                throw MoonlightError(.invalidControlMessage, message: "Controller LED packet is too short")
            }

            return .setControllerLED(.init(
                controllerNumber: readUInt16LE(from: payload, at: 0),
                red: readUInt8(from: payload, at: 2),
                green: readUInt8(from: payload, at: 3),
                blue: readUInt8(from: payload, at: 4)
            ))

        case .hdrMode:
            guard payload.count >= 1 else {
                throw MoonlightError(.invalidControlMessage, message: "HDR packet is too short")
            }

            return .hdrModeChanged(.init(
                enabled: readUInt8(from: payload, at: 0) != 0,
                metadata: parseHDRMetadata(from: payload)
            ))

        case .setAdaptiveTriggers:
            let expectedLength = 5 + AdaptiveTriggerUpdate.effectPayloadSize * 2
            guard payload.count >= expectedLength else {
                throw MoonlightError(.invalidControlMessage, message: "Adaptive trigger packet is too short")
            }

            return .adaptiveTriggers(.init(
                controllerNumber: readUInt16LE(from: payload, at: 0),
                eventFlags: readUInt8(from: payload, at: 2),
                leftTriggerType: readUInt8(from: payload, at: 3),
                rightTriggerType: readUInt8(from: payload, at: 4),
                leftPayload: sliceBytes(from: payload, offset: 5, count: AdaptiveTriggerUpdate.effectPayloadSize),
                rightPayload: sliceBytes(from: payload, offset: 5 + AdaptiveTriggerUpdate.effectPayloadSize, count: AdaptiveTriggerUpdate.effectPayloadSize)
            ))

        case .termination:
            return .terminated(parseTermination(from: payload, context: context))
        }
    }

    private func parseHDRMetadata(from payload: Data.SubSequence) -> HDRMetadata? {
        let metadataOffset = 1
        let metadataLength = 26
        guard payload.count >= metadataOffset + metadataLength else {
            return nil
        }

        var cursor = metadataOffset
        var displayPrimaries: [RawChromaticityPoint] = []
        displayPrimaries.reserveCapacity(3)

        for _ in 0..<3 {
            let x = readUInt16LE(from: payload, at: cursor)
            let y = readUInt16LE(from: payload, at: cursor + 2)
            displayPrimaries.append(.init(x: x, y: y))
            cursor += 4
        }

        let whitePoint = RawChromaticityPoint(
            x: readUInt16LE(from: payload, at: cursor),
            y: readUInt16LE(from: payload, at: cursor + 2)
        )
        cursor += 4

        return HDRMetadata(
            displayPrimaries: displayPrimaries,
            whitePoint: whitePoint,
            maxDisplayLuminance: readUInt16LE(from: payload, at: cursor),
            minDisplayLuminance: readUInt16LE(from: payload, at: cursor + 2),
            maxContentLightLevel: readUInt16LE(from: payload, at: cursor + 4),
            maxFrameAverageLightLevel: readUInt16LE(from: payload, at: cursor + 6),
            maxFullFrameLuminance: readUInt16LE(from: payload, at: cursor + 8)
        )
    }

    private func parseTermination(from payload: Data.SubSequence, context: ControlDecodingContext) -> ConnectionTermination {
        let rawCode: UInt32
        if payload.count >= 4 {
            rawCode = readUInt32BE(from: payload, at: 0)
        } else if payload.count >= 2 {
            rawCode = UInt32(readUInt16LE(from: payload, at: 0))
        } else {
            rawCode = 0
        }

        let reason: ConnectionTerminationReason
        switch rawCode {
        case 0x800E9403:
            reason = .frameConversion
        case 0x800E9302:
            reason = .protectedContent
        case 0x80030023, 0x0100:
            reason = context.hasReceivedVideoFrame ? .graceful : .unexpectedEarly
        default:
            reason = .hostCode(rawCode)
        }

        return ConnectionTermination(rawCode: rawCode, reason: reason)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

private func readUInt8<C: Collection>(from bytes: C, at offset: Int) -> UInt8 where C.Element == UInt8, C.Index == Int {
    bytes[bytes.startIndex.advanced(by: offset)]
}

private func readUInt16LE<C: Collection>(from bytes: C, at offset: Int) -> UInt16 where C.Element == UInt8, C.Index == Int {
    let low = UInt16(readUInt8(from: bytes, at: offset))
    let high = UInt16(readUInt8(from: bytes, at: offset + 1))
    return low | (high << 8)
}

private func readUInt32BE<C: Collection>(from bytes: C, at offset: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
    let b0 = UInt32(readUInt8(from: bytes, at: offset))
    let b1 = UInt32(readUInt8(from: bytes, at: offset + 1))
    let b2 = UInt32(readUInt8(from: bytes, at: offset + 2))
    let b3 = UInt32(readUInt8(from: bytes, at: offset + 3))
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

private func sliceBytes(from bytes: Data.SubSequence, offset: Int, count: Int) -> [UInt8] {
    let start = bytes.startIndex.advanced(by: offset)
    let end = start.advanced(by: count)
    return Array(bytes[start..<end])
}
