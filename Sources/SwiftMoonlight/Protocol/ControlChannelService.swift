import Foundation

public actor ControlChannelService {
    private let transport: ControlChannelTransport
    private let parser: ControlMessageParser
    private let encoder: ControlPacketEncoder
    private let crypto: ControlPacketCrypto
    private let logger: MoonlightLogger
    private var nextEncryptedSequenceNumber: UInt32 = 0

    public init(
        transport: ControlChannelTransport,
        parser: ControlMessageParser = .init(),
        encoder: ControlPacketEncoder = .init(),
        crypto: ControlPacketCrypto = .init(),
        logger: MoonlightLogger
    ) {
        self.transport = transport
        self.parser = parser
        self.encoder = encoder
        self.crypto = crypto
        self.logger = logger
    }

    public func receiveNextMessage(
        context: ControlDecodingContext = .init()
    ) async throws -> ControlMessage? {
        guard let packet = try await transport.receivePacket() else {
            return nil
        }

        return try decodeIncomingPacket(packet, context: context)
    }

    public func decodeIncomingPacket(
        _ packet: Data,
        context: ControlDecodingContext = .init()
    ) throws -> ControlMessage? {
        let message = try parser.parse(packet: packet, context: context)
        if let message {
            logger.debug("Decoded control message: \(String(describing: message))")
        }
        return message
    }

    public func decodeEncryptedIncomingPacket(
        _ packet: Data,
        sender: ControlPacketSender = .host,
        encryption: ControlEncryptionContext,
        context: ControlDecodingContext = .init()
    ) throws -> ControlMessage? {
        let decrypted = try crypto.open(packet: packet, sender: sender, context: encryption)
        return try decodeIncomingPacket(decrypted.packet, context: context)
    }

    public func receiveNextEncryptedMessage(
        sender: ControlPacketSender = .host,
        encryption: ControlEncryptionContext,
        context: ControlDecodingContext = .init()
    ) async throws -> ControlMessage? {
        guard let packet = try await transport.receivePacket() else {
            return nil
        }

        return try decodeEncryptedIncomingPacket(
            packet,
            sender: sender,
            encryption: encryption,
            context: context
        )
    }

    public func send(
        packet: Data,
        channelID: UInt8 = ControlChannelID.generic,
        reliable: Bool = true
    ) async throws {
        try await transport.send(packet: packet, channelID: channelID, reliable: reliable)
    }

    public func snapshotTransportMetrics() async -> ControlTransportMetricsSnapshot? {
        guard let metricsTransport = transport as? any ControlTransportMetricsReporting else {
            return nil
        }
        return await metricsTransport.snapshotControlTransportMetrics()
    }

    public func sendEncrypted(
        packetType: UInt16,
        payload: Data,
        sequenceNumber: UInt32,
        channelID: UInt8 = ControlChannelID.generic,
        reliable: Bool = true,
        sender: ControlPacketSender = .client,
        encryption: ControlEncryptionContext
    ) async throws {
        if let typedTransport = transport as? any TypedControlPacketTransport {
            try await typedTransport.sendControlPayload(
                packetType: packetType,
                payload: payload,
                channelID: channelID,
                reliable: reliable,
                encryption: encryption
            )
            return
        }

        let packet = try crypto.seal(
            packetType: packetType,
            payload: payload,
            sequenceNumber: sequenceNumber,
            sender: sender,
            context: encryption
        )
        try await send(packet: packet, channelID: channelID, reliable: reliable)
    }

    public func requestIDRFrame(encryption: ControlEncryptionContext? = nil) async throws {
        if let encryption {
            try await sendEncrypted(
                packetType: ControlPacketType.requestIDRFrame.rawValue,
                payload: Data([0x00, 0x00]),
                sequenceNumber: allocateEncryptedSequenceNumber(),
                channelID: ControlChannelID.urgent,
                reliable: true,
                sender: .client,
                encryption: encryption
            )
        } else {
            try await send(
                packet: encoder.requestIDRFramePacket(),
                channelID: ControlChannelID.urgent,
                reliable: true
            )
        }
    }

    public func sendFrameFECStatus(
        _ status: VideoFrameFECStatus,
        encryption: ControlEncryptionContext? = nil
    ) async throws {
        if let encryption {
            try await sendEncrypted(
                packetType: ControlPacketEncoder.frameFECStatusPacketType,
                payload: encoder.frameFECStatusPayload(status),
                sequenceNumber: allocateEncryptedSequenceNumber(),
                channelID: ControlChannelID.generic,
                reliable: false,
                sender: .client,
                encryption: encryption
            )
        } else {
            try await send(
                packet: encoder.frameFECStatusPacket(status),
                channelID: ControlChannelID.generic,
                reliable: false
            )
        }
    }

    private func allocateEncryptedSequenceNumber() -> UInt32 {
        defer {
            nextEncryptedSequenceNumber &+= 1
        }
        return nextEncryptedSequenceNumber
    }
}
