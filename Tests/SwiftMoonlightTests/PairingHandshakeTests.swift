import Testing
@testable import SwiftMoonlight

@Test
func pairingHandshakeAcceptsValidPhaseOrder() throws {
    var machine = PairingHandshakeMachine()

    try machine.advance(to: .getServerCert)
    try machine.advance(to: .clientChallenge)
    try machine.advance(to: .serverChallengeResponse)
    try machine.advance(to: .clientPairingSecret)
    try machine.advance(to: .completed)

    #expect(machine.state == .completed)
}

@Test
func pairingHandshakeRejectsOutOfOrderPhase() {
    var machine = PairingHandshakeMachine()

    do {
        try machine.advance(to: .clientChallenge)
        Issue.record("Expected out-of-order phase to fail")
    } catch let error as MoonlightError {
        #expect(error.code == .invalidStateTransition)
        #expect(machine.state == .idle)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
