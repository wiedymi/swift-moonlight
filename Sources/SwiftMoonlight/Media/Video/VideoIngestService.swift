import Foundation

public enum VideoPipelineSubmissionMode: Sendable, Equatable {
    case synchronous
    case asynchronous(maxInFlightFrames: Int)

    var boundedMaxInFlightFrames: Int? {
        switch self {
        case .synchronous:
            return nil
        case .asynchronous(let maxInFlightFrames):
            return max(1, maxInFlightFrames)
        }
    }
}

public actor VideoIngestService {
    private let source: MediaPacketSource
    private let decryptor: VideoPacketDecryptor?
    private let encryptionContext: VideoEncryptionContext?
    private let parser: VideoPacketParser
    private let depacketizer: SimpleVideoDepacketizer
    private let pipeline: MediaPipeline
    private let packetTraceLimit: Int
    private let pipelineSubmissionMode: VideoPipelineSubmissionMode
    private var observedPacketCount = 0
    private var recoverableDecodeFailureCount = 0
    private var packetTrace: [VideoPacketTraceEntry] = []
    private var pendingPipelineError: MoonlightError?
    private var inFlightPipelineTasks: [Task<Void, Never>] = []

    public init(
        source: MediaPacketSource,
        decryptor: VideoPacketDecryptor? = nil,
        encryptionContext: VideoEncryptionContext? = nil,
        parser: VideoPacketParser = .init(),
        depacketizer: SimpleVideoDepacketizer,
        pipeline: MediaPipeline,
        packetTraceLimit: Int = 0,
        pipelineSubmissionMode: VideoPipelineSubmissionMode = .synchronous
    ) {
        self.source = source
        self.decryptor = decryptor
        self.encryptionContext = encryptionContext
        self.parser = parser
        self.depacketizer = depacketizer
        self.pipeline = pipeline
        self.packetTraceLimit = max(0, packetTraceLimit)
        self.pipelineSubmissionMode = pipelineSubmissionMode
    }

    public func receiveNextFrame() async throws -> EncodedVideoFrame? {
        try throwPendingPipelineErrorIfNeeded()

        while let packetData = try await source.receivePacket() {
            try throwPendingPipelineErrorIfNeeded()
            if let frame = try await processVideoPacketData(packetData) {
                try await submitVideoFrameToPipeline(frame)
                return frame
            }
        }
        try await waitForInFlightPipelineTasks()
        try throwPendingPipelineErrorIfNeeded()
        return nil
    }

    public func flushForKeyframeRequest() async {
        for task in inFlightPipelineTasks {
            task.cancel()
        }
        inFlightPipelineTasks.removeAll(keepingCapacity: true)
        pendingPipelineError = nil
        await depacketizer.flushForKeyframeRequest()
    }

    public func drainPendingFrameFECStatuses() async -> [VideoFrameFECStatus] {
        await depacketizer.drainPendingFrameFECStatuses()
    }

    public func snapshotObservedPacketCount() -> Int {
        observedPacketCount
    }

    public func snapshotReorderedPacketCount() async -> Int {
        await depacketizer.snapshotReorderedPacketCount()
    }

    public func snapshotDiscontinuityCount() async -> Int {
        await depacketizer.snapshotDiscontinuityCount()
    }

    public func snapshotMissingPacketCount() async -> Int {
        await depacketizer.snapshotMissingPacketCount()
    }

    public func snapshotRecoverableDecodeFailureCount() -> Int {
        recoverableDecodeFailureCount
    }

    public func snapshotPacketTrace() -> [VideoPacketTraceEntry] {
        packetTrace
    }

    public func snapshot() async -> VideoIngestSnapshot {
        let depacketizerSnapshot = await depacketizer.snapshot()
        return VideoIngestSnapshot(
            observedPacketCount: observedPacketCount,
            reorderedPacketCount: depacketizerSnapshot.reorderedPacketCount,
            missingPacketCount: depacketizerSnapshot.missingPacketCount,
            discontinuityCount: depacketizerSnapshot.discontinuityCount,
            recoverableDecodeFailureCount: recoverableDecodeFailureCount,
            packetTrace: packetTrace
        )
    }

    private func processVideoPacketData(_ packetData: Data) async throws -> EncodedVideoFrame? {
        observedPacketCount += 1
        let rawPacket: Data
        let usedDecryptor = decryptor != nil && encryptionContext != nil
        if let decryptor, let encryptionContext {
            rawPacket = try decryptor.decrypt(packetData, context: encryptionContext)
        } else {
            rawPacket = packetData
        }
        let packet: VideoTransportPacket
        do {
            var parsedPacket = try parser.parse(rawPacket)
            let usedSyntheticSequenceNumber = !isLikelyRTPv2(rawPacket)
            if usedSyntheticSequenceNumber {
                parsedPacket.rtp.sequenceNumber = UInt16(truncatingIfNeeded: observedPacketCount)
            }
            recordPacketTrace(
                packet: parsedPacket,
                observedPacketIndex: observedPacketCount,
                usedDecryptor: usedDecryptor,
                usedSyntheticSequenceNumber: usedSyntheticSequenceNumber,
                encryptedByteCount: packetData.count,
                rawByteCount: rawPacket.count
            )
            packet = parsedPacket
        } catch {
            throw enrichVideoPacketError(
                error,
                observedPacketCount: observedPacketCount,
                usedDecryptor: usedDecryptor,
                packetData: packetData,
                rawPacket: rawPacket
            )
        }

        return try await depacketizer.submit(packet)
    }

    private func submitVideoFrameToPipeline(_ frame: EncodedVideoFrame) async throws {
        let queuedAt = ContinuousClock().now
        guard let maxInFlightFrames = pipelineSubmissionMode.boundedMaxInFlightFrames else {
            do {
                try await pipeline.ingestVideo(frame, queuedAt: queuedAt)
            } catch {
                guard Self.isRecoverableVideoDecodeError(error) else {
                    throw error
                }
                recoverableDecodeFailureCount += 1
            }
            return
        }

        try await applyPipelineBackpressure(maxInFlightFrames: maxInFlightFrames)
        let previousTask = inFlightPipelineTasks.last
        let task = Task.detached { [pipeline, previousTask] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else {
                return
            }
            do {
                try await pipeline.ingestVideo(frame, queuedAt: queuedAt)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await self.recordPipelineError(error)
            }
        }
        inFlightPipelineTasks.append(task)
    }

    private func applyPipelineBackpressure(maxInFlightFrames: Int) async throws {
        while inFlightPipelineTasks.count >= maxInFlightFrames {
            let task = inFlightPipelineTasks.removeFirst()
            await task.value
            try throwPendingPipelineErrorIfNeeded()
        }
    }

    private func waitForInFlightPipelineTasks() async throws {
        while !inFlightPipelineTasks.isEmpty {
            let task = inFlightPipelineTasks.removeFirst()
            await task.value
            try throwPendingPipelineErrorIfNeeded()
        }
    }

    private func recordPipelineError(_ error: Error) {
        if Self.isRecoverableVideoDecodeError(error) {
            recoverableDecodeFailureCount += 1
        } else if pendingPipelineError == nil {
            pendingPipelineError = Self.makePipelineError(error)
        }
    }

    private func throwPendingPipelineErrorIfNeeded() throws {
        guard let pendingPipelineError else {
            return
        }

        self.pendingPipelineError = nil
        throw pendingPipelineError
    }

    private static func makePipelineError(_ error: Error) -> MoonlightError {
        if let typed = error as? MoonlightError {
            return typed
        }

        return MoonlightError(.unsupportedOperation, message: String(describing: error))
    }

    private static func isRecoverableVideoDecodeError(_ error: Error) -> Bool {
        guard let typed = error as? MoonlightError else {
            return false
        }
        return typed.message.contains("VideoToolbox decode failed: -12909")
    }

    private func recordPacketTrace(
        packet: VideoTransportPacket,
        observedPacketIndex: Int,
        usedDecryptor: Bool,
        usedSyntheticSequenceNumber: Bool,
        encryptedByteCount: Int,
        rawByteCount: Int
    ) {
        guard packetTraceLimit > 0 else {
            return
        }

        let entry = VideoPacketTraceEntry(
            observedPacketIndex: observedPacketIndex,
            usedDecryptor: usedDecryptor,
            usedSyntheticSequenceNumber: usedSyntheticSequenceNumber,
            encryptedByteCount: encryptedByteCount,
            rawByteCount: rawByteCount,
            sequenceNumber: packet.rtp.sequenceNumber,
            packetType: packet.rtp.packetType,
            timestamp: packet.rtp.timestamp,
            streamPacketIndex: packet.video.streamPacketIndex,
            frameIndex: packet.video.frameIndex,
            flags: packet.video.flags,
            fecShardIndex: packet.video.fecShardIndex,
            dataShardCount: packet.video.dataShardCount,
            fecPercentage: packet.video.fecPercentage,
            fecBlockIndex: packet.video.fecBlockIndex,
            fecLastBlockIndex: packet.video.fecLastBlockIndex,
            isStartOfFrame: packet.video.isStartOfFrame,
            isEndOfFrame: packet.video.isEndOfFrame,
            isParityShard: packet.video.isParityShard
        )
        packetTrace.append(entry)
        if packetTrace.count > packetTraceLimit {
            packetTrace.removeFirst(packetTrace.count - packetTraceLimit)
        }
    }

    private func enrichVideoPacketError(
        _ error: Error,
        observedPacketCount: Int,
        usedDecryptor: Bool,
        packetData: Data,
        rawPacket: Data
    ) -> Error {
        let headerBytes = rawPacket.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let encryptedHeaderBytes = packetData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let baseMessage: String
        if let typed = error as? MoonlightError {
            baseMessage = typed.message
        } else {
            baseMessage = error.localizedDescription
        }
        return MoonlightError(
            .invalidControlMessage,
            message: "\(baseMessage) [video packet #\(observedPacketCount), decrypted=\(usedDecryptor), encryptedLen=\(packetData.count), rawLen=\(rawPacket.count), encryptedPrefix=\(encryptedHeaderBytes), rawPrefix=\(headerBytes)]"
        )
    }
}
