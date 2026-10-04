import Foundation

public actor AudioIngestService {
    private let source: MediaPacketSource
    private let decryptor: AudioPacketDecryptor?
    private let encryptionContext: AudioEncryptionContext?
    private let parser: AudioPacketParser
    private let depacketizer: SimpleAudioDepacketizer
    private let pipeline: MediaPipeline
    private var observedPacketCount = 0
    private var concealedPacketCount = 0

    public init(
        source: MediaPacketSource,
        decryptor: AudioPacketDecryptor? = nil,
        encryptionContext: AudioEncryptionContext? = nil,
        parser: AudioPacketParser = .init(),
        depacketizer: SimpleAudioDepacketizer = .init(),
        pipeline: MediaPipeline
    ) {
        self.source = source
        self.decryptor = decryptor
        self.encryptionContext = encryptionContext
        self.parser = parser
        self.depacketizer = depacketizer
        self.pipeline = pipeline
    }

    public func receiveNextPacket() async throws -> EncodedAudioPacket? {
        while true {
            if let ready = await depacketizer.drainPendingAudioPackets() {
                try await pipeline.ingestAudio(ready)
                return ready
            }
            guard let packetData = try await source.receivePacket() else { return nil }
            observedPacketCount += 1
            let rawPacket: Data
            let usedDecryptor = decryptor != nil && encryptionContext != nil
            if let decryptor, let encryptionContext {
                rawPacket = try decryptor.decrypt(packetData, context: encryptionContext)
            } else {
                rawPacket = packetData
            }
            let packet: AudioTransportPacket
            do {
                packet = try parser.parse(rawPacket)
            } catch {
                let enriched = enrichAudioPacketError(
                    error,
                    observedPacketCount: observedPacketCount,
                    usedDecryptor: usedDecryptor,
                    packetData: packetData,
                    rawPacket: rawPacket
                )
                if let typed = enriched as? MoonlightError,
                   typed.code == .invalidControlMessage
                {
                    continue
                }
                throw enriched
            }
            if let encoded = try await depacketizer.submit(packet) {
                if encoded.isConcealment {
                    concealedPacketCount += 1
                }
                try await pipeline.ingestAudio(encoded)
                return encoded
            }
        }
    }

    public func snapshotObservedPacketCount() -> Int {
        observedPacketCount
    }

    public func snapshotConcealedPacketCount() async -> Int {
        max(concealedPacketCount, await depacketizer.snapshotConcealedPacketCount())
    }

    public func snapshotReorderedPacketCount() async -> Int {
        await depacketizer.snapshotReorderedPacketCount()
    }

    public func snapshotMissingPacketCount() async -> Int {
        await depacketizer.snapshotMissingPacketCount()
    }

    private func enrichAudioPacketError(
        _ error: Error,
        observedPacketCount: Int,
        usedDecryptor: Bool,
        packetData: Data,
        rawPacket: Data
    ) -> Error {
        let headerBytes = rawPacket.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let encryptedHeaderBytes = packetData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let payloadType = rawPacket.count >= 2 ? Int(rawPacket[1] & 0x7F) : -1
        let baseMessage: String
        if let typed = error as? MoonlightError {
            baseMessage = typed.message
        } else {
            baseMessage = error.localizedDescription
        }
        return MoonlightError(
            .invalidControlMessage,
            message: "\(baseMessage) [audio packet #\(observedPacketCount), decrypted=\(usedDecryptor), payloadType=\(payloadType), encryptedLen=\(packetData.count), rawLen=\(rawPacket.count), encryptedPrefix=\(encryptedHeaderBytes), rawPrefix=\(headerBytes)]"
        )
    }
}
