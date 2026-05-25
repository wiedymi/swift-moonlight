import Dispatch
import Foundation

public protocol InputSending: Sendable {
    func send(_ event: InputEvent) async throws
}

public protocol InputFlushing: Sendable {
    func flushPendingInput() async throws
}

public protocol InputMetricsReporting: Sendable {
    func snapshotInputMetrics() async -> InputSenderMetrics
}

public struct InputSenderMetrics: Sendable, Equatable {
    public var inputPacketsSent: Int
    public var averageInputQueueLatencyMs: Double?
    public var maxInputQueueLatencyMs: Double?
    public var averageInputTransportLatencyMs: Double?
    public var maxInputTransportLatencyMs: Double?

    public init(
        inputPacketsSent: Int = 0,
        averageInputQueueLatencyMs: Double? = nil,
        maxInputQueueLatencyMs: Double? = nil,
        averageInputTransportLatencyMs: Double? = nil,
        maxInputTransportLatencyMs: Double? = nil
    ) {
        self.inputPacketsSent = inputPacketsSent
        self.averageInputQueueLatencyMs = averageInputQueueLatencyMs
        self.maxInputQueueLatencyMs = maxInputQueueLatencyMs
        self.averageInputTransportLatencyMs = averageInputTransportLatencyMs
        self.maxInputTransportLatencyMs = maxInputTransportLatencyMs
    }
}

public struct EncodedInputPacket: Sendable, Equatable {
    public var payload: Data
    public var channelID: UInt8
    public var reliable: Bool

    public init(payload: Data, channelID: UInt8, reliable: Bool) {
        self.payload = payload
        self.channelID = channelID
        self.reliable = reliable
    }

    public var hexString: String {
        payload.map { String(format: "%02X", $0) }.joined()
    }
}

public protocol InputPacketTransport: Sendable {
    func send(_ packet: Data, channelID: UInt8, reliable: Bool) async throws
}

public enum MouseMotionDeliveryPolicy: Sendable, Equatable {
    case coalesced(interval: Duration)
    case immediate
}

public struct InputSenderConfiguration: Sendable, Equatable {
    public var mouseMotionDeliveryPolicy: MouseMotionDeliveryPolicy

    public init(
        mouseMotionDeliveryPolicy: MouseMotionDeliveryPolicy = .coalesced(interval: .milliseconds(1))
    ) {
        self.mouseMotionDeliveryPolicy = mouseMotionDeliveryPolicy
    }
}

public actor InputSender: InputSending, InputFlushing, InputMetricsReporting {
    private struct PendingMouseMotion: Sendable {
        var motion: InputMouseMotionBatch
        var queuedAtNanos: UInt64
    }

    private let encoder: any InputEncoder
    private let transport: any InputPacketTransport
    private let context: InputEncodingContext
    private let configuration: InputSenderConfiguration
    private var pendingMouseMotion: PendingMouseMotion?
    private var pendingMouseFlushTask: Task<Void, Never>?
    private var isFlushingMouseMotion = false
    private var mouseIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var packetsSent = 0
    private var queueLatencySamples = 0
    private var totalQueueLatencyMs = 0.0
    private var maxQueueLatencyMs: Double?
    private var transportLatencySamples = 0
    private var totalTransportLatencyMs = 0.0
    private var maxTransportLatencyMs: Double?

    public init(
        encoder: any InputEncoder = BinaryInputEncoder(),
        context: InputEncodingContext,
        transport: any InputPacketTransport,
        configuration: InputSenderConfiguration = .init()
    ) {
        self.encoder = encoder
        self.context = context
        self.transport = transport
        self.configuration = configuration
    }

    public func send(_ event: InputEvent) async throws {
        switch event {
        case let .mouse(.relativeMove(dx, dy)):
            enqueueMouseMotion(.relative(dx: Int(dx), dy: Int(dy)))
            if configuration.mouseMotionDeliveryPolicy == .immediate {
                try await flushPendingMouseMotionAndWaitUntilIdle()
            }
            return
        case let .mouse(.absoluteMove(x, y)):
            enqueueMouseMotion(.absolute(x: x, y: y))
            if configuration.mouseMotionDeliveryPolicy == .immediate {
                try await flushPendingMouseMotionAndWaitUntilIdle()
            }
            return
        default:
            try await flushPendingMouseMotionAndWaitUntilIdle()
            try await sendImmediately(event)
        }
    }

    public func flushPendingMouseMotion() async throws {
        try await flushPendingMouseMotionAndWaitUntilIdle()
    }

    public func flushPendingInput() async throws {
        try await flushPendingMouseMotion()
    }

    public func snapshotInputMetrics() -> InputSenderMetrics {
        InputSenderMetrics(
            inputPacketsSent: packetsSent,
            averageInputQueueLatencyMs: average(totalQueueLatencyMs, samples: queueLatencySamples),
            maxInputQueueLatencyMs: maxQueueLatencyMs,
            averageInputTransportLatencyMs: average(totalTransportLatencyMs, samples: transportLatencySamples),
            maxInputTransportLatencyMs: maxTransportLatencyMs
        )
    }

    private func sendImmediately(_ event: InputEvent, queuedAtNanos: UInt64? = nil) async throws {
        let packets = try encoder.encode(event, context: context)
        for packet in packets {
            recordQueueLatency(from: queuedAtNanos)
            let startedAt = Self.nowNanos()
            try await transport.send(packet.payload, channelID: packet.channelID, reliable: packet.reliable)
            recordTransportLatency(startedAt: startedAt)
            packetsSent += 1
        }
    }

    private func enqueueMouseMotion(_ motion: InputMouseMotionBatch) {
        let now = Self.nowNanos()
        if let pending = pendingMouseMotion {
            pendingMouseMotion = PendingMouseMotion(
                motion: pending.motion.merged(with: motion),
                queuedAtNanos: pendingQueueTimestamp(existing: pending, next: motion, now: now)
            )
        } else {
            pendingMouseMotion = PendingMouseMotion(motion: motion, queuedAtNanos: now)
        }
        if case .coalesced = configuration.mouseMotionDeliveryPolicy {
            schedulePendingMouseFlushIfNeeded()
        }
    }

    private func schedulePendingMouseFlushIfNeeded() {
        guard pendingMouseFlushTask == nil else {
            return
        }

        guard case .coalesced(let interval) = configuration.mouseMotionDeliveryPolicy else {
            return
        }

        pendingMouseFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.flushPendingMouseMotionFromTask()
        }
    }

    private func flushPendingMouseMotionFromTask() async {
        pendingMouseFlushTask = nil

        do {
            try await flushPendingMouseMotionAndWaitUntilIdle()
        } catch {
            // Motion batching should not tear down the session because a later button/key event
            // will surface the same transport failure on the normal send path.
        }
    }

    private func flushPendingMouseMotionAndWaitUntilIdle() async throws {
        pendingMouseFlushTask?.cancel()
        pendingMouseFlushTask = nil

        while true {
            if isFlushingMouseMotion {
                await waitForMouseMotionToBecomeIdle()
                continue
            }

            guard pendingMouseMotion != nil else {
                resumeMouseIdleWaitersIfNeeded()
                return
            }

            try await flushPendingMouseMotionNow()
        }
    }

    private func flushPendingMouseMotionNow() async throws {
        guard !isFlushingMouseMotion else {
            return
        }

        isFlushingMouseMotion = true
        defer {
            isFlushingMouseMotion = false
            resumeMouseIdleWaitersIfNeeded()
        }

        while let motion = pendingMouseMotion {
            pendingMouseMotion = nil
            for mouseEvent in motion.motion.mouseEvents {
                try await sendImmediately(.mouse(mouseEvent), queuedAtNanos: motion.queuedAtNanos)
            }
        }
    }

    private func waitForMouseMotionToBecomeIdle() async {
        guard isFlushingMouseMotion || pendingMouseMotion != nil else {
            return
        }

        await withCheckedContinuation { continuation in
            mouseIdleWaiters.append(continuation)
        }
    }

    private func resumeMouseIdleWaitersIfNeeded() {
        guard !isFlushingMouseMotion, pendingMouseMotion == nil else {
            return
        }

        let waiters = mouseIdleWaiters
        mouseIdleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func pendingQueueTimestamp(
        existing: PendingMouseMotion,
        next: InputMouseMotionBatch,
        now: UInt64
    ) -> UInt64 {
        switch (existing.motion, next) {
        case (.relative, .relative):
            return existing.queuedAtNanos
        default:
            // Absolute motion keeps only the latest position, and a relative
            // move after an absolute position replaces the absolute packet.
            // Measure latency from the event that survives coalescing.
            return now
        }
    }

    private func recordQueueLatency(from queuedAtNanos: UInt64?) {
        guard let queuedAtNanos else {
            return
        }

        let elapsedMs = Self.elapsedMilliseconds(startedAt: queuedAtNanos)
        queueLatencySamples += 1
        totalQueueLatencyMs += elapsedMs
        maxQueueLatencyMs = max(maxQueueLatencyMs ?? elapsedMs, elapsedMs)
    }

    private func recordTransportLatency(startedAt: UInt64) {
        let elapsedMs = Self.elapsedMilliseconds(startedAt: startedAt)
        transportLatencySamples += 1
        totalTransportLatencyMs += elapsedMs
        maxTransportLatencyMs = max(maxTransportLatencyMs ?? elapsedMs, elapsedMs)
    }

    private func average(_ total: Double, samples: Int) -> Double? {
        guard samples > 0 else {
            return nil
        }
        return total / Double(samples)
    }

    private static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func elapsedMilliseconds(startedAt: UInt64) -> Double {
        let now = nowNanos()
        guard now >= startedAt else {
            return 0
        }
        return Double(now - startedAt) / 1_000_000.0
    }
}
