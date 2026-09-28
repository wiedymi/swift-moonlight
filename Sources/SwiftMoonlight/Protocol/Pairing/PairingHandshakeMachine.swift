public enum PairingHandshakePhase: Sendable {
    case idle
    case getServerCert
    case clientChallenge
    case serverChallengeResponse
    case clientPairingSecret
    case completed
}

public struct PairingHandshakeMachine: Sendable {
    public private(set) var state: PairingHandshakePhase

    public init(initialState: PairingHandshakePhase = .idle) {
        self.state = initialState
    }

    public mutating func advance(to nextPhase: PairingHandshakePhase) throws {
        guard Self.allowedTransitions[state, default: []].contains(nextPhase) else {
            throw MoonlightError(
                .invalidStateTransition,
                message: "Invalid pairing transition from \(state) to \(nextPhase)"
            )
        }

        state = nextPhase
    }

    private static let allowedTransitions: [PairingHandshakePhase: Set<PairingHandshakePhase>] = [
        .idle: [.getServerCert],
        .getServerCert: [.clientChallenge],
        .clientChallenge: [.serverChallengeResponse],
        .serverChallengeResponse: [.clientPairingSecret],
        .clientPairingSecret: [.completed],
        .completed: [],
    ]
}
