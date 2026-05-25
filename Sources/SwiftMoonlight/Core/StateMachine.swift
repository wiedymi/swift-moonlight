public enum SessionState: Sendable {
    case idle
    case discovering
    case pairing
    case paired
    case launching
    case connecting
    case streaming
    case stopping
    case stopped
    case failed
}

public struct SessionLifecycleMachine: Sendable {
    public private(set) var state: SessionState

    public init(initialState: SessionState = .idle) {
        self.state = initialState
    }

    public mutating func transition(to newState: SessionState) throws {
        guard Self.allowedTransitions[state, default: []].contains(newState) else {
            throw MoonlightError(
                .invalidStateTransition,
                message: "Invalid transition from \(state) to \(newState)"
            )
        }

        state = newState
    }

    private static let allowedTransitions: [SessionState: Set<SessionState>] = [
        .idle: [.discovering, .pairing, .paired, .connecting, .failed],
        .discovering: [.idle, .pairing, .paired, .failed],
        .pairing: [.paired, .failed],
        .paired: [.launching, .failed],
        .launching: [.connecting, .failed],
        .connecting: [.streaming, .stopping, .failed],
        .streaming: [.stopping, .failed],
        .stopping: [.stopped, .failed],
        .stopped: [.connecting, .failed],
        .failed: [.idle],
    ]
}
