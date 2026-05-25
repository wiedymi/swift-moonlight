import Foundation

public struct InputDispatchFailure: Sendable, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public actor InputEventDispatchQueue {
    public typealias FailureHandler = @Sendable (InputDispatchFailure) async -> Void

    private struct QueuedInput: Sendable {
        let event: InputEvent
        let sender: any InputSending
    }

    private let onFailure: FailureHandler
    private var generation: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var pendingIngress: [UInt64: QueuedInput] = [:]
    private var queue: [QueuedInput] = []
    private var queueHead = 0
    private var pendingMouseMotion: (motion: InputMouseMotionBatch, sender: any InputSending)?
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(onFailure: @escaping FailureHandler = { _ in }) {
        self.onFailure = onFailure
    }

    public func enqueue(
        _ event: InputEvent,
        sender: any InputSending,
        sequence: UInt64,
        generation: UInt64
    ) {
        guard generation == self.generation else {
            return
        }

        pendingIngress[sequence] = QueuedInput(event: event, sender: sender)
        moveReadyIngressIntoQueue()
        guard queueHead < queue.count || pendingMouseMotion != nil else {
            return
        }
        startDrainingIfNeeded()
    }

    public func clear(generation: UInt64) {
        self.generation = generation
        nextSequence = 0
        pendingIngress.removeAll(keepingCapacity: false)
        queue.removeAll(keepingCapacity: false)
        queueHead = 0
        pendingMouseMotion = nil
        resumeIdleWaitersIfNeeded()
    }

    public func waitUntilIdle() async {
        guard isDraining || !pendingIngress.isEmpty || queueHead < queue.count || pendingMouseMotion != nil else {
            return
        }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func enqueueOrdered(_ event: InputEvent, sender: any InputSending) {
        switch event {
        case let .mouse(mouseEvent):
            switch mouseEvent {
            case .relativeMove, .absoluteMove:
                guard let motion = InputMouseMotionBatch(mouseEvent) else { return }
                mergePendingMouseMotion(motion, sender: sender)
            default:
                flushPendingMouseMotionIntoQueueIfNeeded()
                queue.append(QueuedInput(event: event, sender: sender))
            }
        default:
            flushPendingMouseMotionIntoQueueIfNeeded()
            queue.append(QueuedInput(event: event, sender: sender))
        }
    }

    private func moveReadyIngressIntoQueue() {
        while let next = pendingIngress.removeValue(forKey: nextSequence) {
            nextSequence &+= 1
            enqueueOrdered(next.event, sender: next.sender)
        }
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }

        isDraining = true
        Task(priority: .userInitiated) {
            await self.drainQueue()
        }
    }

    private func drainQueue() async {
        while true {
            let next: QueuedInput?
            if queueHead < queue.count {
                next = queue[queueHead]
                queueHead += 1
                compactQueueIfNeeded()
            } else if let pendingMouseMotion {
                self.pendingMouseMotion = nil
                let inputEvents = pendingMouseMotion.motion.inputEvents
                if let first = inputEvents.first {
                    queue.append(contentsOf: inputEvents.dropFirst().map {
                        QueuedInput(event: $0, sender: pendingMouseMotion.sender)
                    })
                    next = QueuedInput(event: first, sender: pendingMouseMotion.sender)
                } else {
                    next = nil
                }
            } else {
                next = nil
            }

            guard let next else {
                break
            }

            do {
                try await next.sender.send(next.event)
            } catch {
                await onFailure(InputDispatchFailure(message: Self.message(for: error)))
            }
        }

        isDraining = false
        if queueHead < queue.count || pendingMouseMotion != nil {
            isDraining = true
            Task(priority: .userInitiated) {
                await self.drainQueue()
            }
        } else {
            resumeIdleWaitersIfNeeded()
        }
    }

    private func mergePendingMouseMotion(_ motion: InputMouseMotionBatch, sender: any InputSending) {
        if let pendingMouseMotion {
            self.pendingMouseMotion = (pendingMouseMotion.motion.merged(with: motion), sender)
        } else {
            pendingMouseMotion = (motion, sender)
        }
    }

    private func flushPendingMouseMotionIntoQueueIfNeeded() {
        guard let pendingMouseMotion else {
            return
        }
        queue.append(contentsOf: pendingMouseMotion.motion.inputEvents.map {
            QueuedInput(event: $0, sender: pendingMouseMotion.sender)
        })
        self.pendingMouseMotion = nil
    }

    private func compactQueueIfNeeded() {
        guard queueHead > 32, queueHead * 2 >= queue.count else {
            return
        }
        queue.removeFirst(queueHead)
        queueHead = 0
    }

    private func resumeIdleWaitersIfNeeded() {
        guard !isDraining, pendingIngress.isEmpty, queueHead >= queue.count, pendingMouseMotion == nil else {
            return
        }

        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func message(for error: Error) -> String {
        if let moonlightError = error as? MoonlightError {
            return moonlightError.message
        }
        return error.localizedDescription
    }
}
