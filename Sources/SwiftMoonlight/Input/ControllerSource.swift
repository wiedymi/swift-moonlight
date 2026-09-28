import Foundation
#if canImport(GameController)
import GameController
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

public struct ControllerSnapshot: Sendable, Equatable {
    public var descriptor: ControllerDescriptor
    public var state: ControllerState
    public var battery: ControllerBattery?
    public var motion: [ControllerMotion]
    public var touchpad: ControllerTouchpadEvent?

    public init(
        descriptor: ControllerDescriptor,
        state: ControllerState,
        battery: ControllerBattery? = nil,
        motion: [ControllerMotion] = [],
        touchpad: ControllerTouchpadEvent? = nil
    ) {
        self.descriptor = descriptor
        self.state = state
        self.battery = battery
        self.motion = motion
        self.touchpad = touchpad
    }
}

public protocol ControllerSnapshotProvider: Sendable {
    func snapshots() async -> [ControllerSnapshot]
}

public protocol ControllerSource: Sendable {
    var events: AsyncStream<ControllerEvent> { get }
    func start() async
    func stop() async
}

public actor PollingControllerSource: ControllerSource {
    public nonisolated let events: AsyncStream<ControllerEvent>

    private let continuation: AsyncStream<ControllerEvent>.Continuation
    private let provider: any ControllerSnapshotProvider
    private let pollInterval: Duration
    private var lastSnapshots: [ControllerID: ControllerSnapshot] = [:]
    private var pollTask: Task<Void, Never>?

    public init(
        provider: any ControllerSnapshotProvider,
        pollInterval: Duration = .milliseconds(16)
    ) {
        let stream = AsyncStream.makeStream(of: ControllerEvent.self)
        self.events = stream.stream
        self.continuation = stream.continuation
        self.provider = provider
        self.pollInterval = pollInterval
    }

    public func start() {
        guard pollTask == nil else {
            return
        }

        pollTask = Task {
            await pollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let snapshots = await provider.snapshots()
            publishDifferences(nextSnapshots: snapshots)
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func publishDifferences(nextSnapshots: [ControllerSnapshot]) {
        let nextByID = Dictionary(uniqueKeysWithValues: nextSnapshots.map { ($0.descriptor.id, $0) })

        for (id, snapshot) in nextByID where lastSnapshots[id] == nil {
            continuation.yield(.connected(snapshot.descriptor))
            continuation.yield(.stateChanged(snapshot.state))
            if let battery = snapshot.battery {
                continuation.yield(.battery(battery))
            }
            for motion in snapshot.motion {
                continuation.yield(.motion(motion))
            }
            if let touchpad = snapshot.touchpad {
                continuation.yield(.touchpad(touchpad))
            }
        }

        for (id, previous) in lastSnapshots {
            guard let current = nextByID[id] else {
                continuation.yield(.disconnected(id))
                continue
            }

            if previous.state != current.state {
                continuation.yield(.stateChanged(current.state))
            }
            if previous.battery != current.battery, let battery = current.battery {
                continuation.yield(.battery(battery))
            }
            if previous.motion != current.motion {
                for motion in current.motion {
                    continuation.yield(.motion(motion))
                }
            }
            if previous.touchpad != current.touchpad, let touchpad = current.touchpad {
                continuation.yield(.touchpad(touchpad))
            }
        }

        lastSnapshots = nextByID
    }
}

public actor ControllerSessionBridge {
    private let source: any ControllerSource
    private let session: MoonlightSession
    private var forwardTask: Task<Void, Never>?

    public init(source: any ControllerSource, session: MoonlightSession) {
        self.source = source
        self.session = session
    }

    public func start() async {
        guard forwardTask == nil else {
            return
        }

        await source.start()
        let stream = source.events
        forwardTask = Task {
            for await event in stream {
                try? await session.send(.controller(event))
            }
        }
    }

    public func stop() async {
        forwardTask?.cancel()
        forwardTask = nil
        await source.stop()
    }
}
