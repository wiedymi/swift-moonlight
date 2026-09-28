import Foundation

public struct PairingService: Sendable {
    public let transport: any PairingTransport
    public let requestBuilder: PairingRequestBuilder
    public let responseParser: PairingResponseParser

    public init(
        transport: any PairingTransport,
        requestBuilder: PairingRequestBuilder = PairingRequestBuilder(),
        responseParser: PairingResponseParser = PairingResponseParser()
    ) {
        self.transport = transport
        self.requestBuilder = requestBuilder
        self.responseParser = responseParser
    }

    public func performHandshake(
        host: MoonlightHost,
        material: PairingMaterial
    ) async throws -> PairingExchange {
        var machine = PairingHandshakeMachine()

        try machine.advance(to: .getServerCert)
        let serverCertResponse = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.getServerCertQuery(
                host: host,
                uniqueID: material.uniqueID,
                clientCertificateHex: material.clientCertificateHex,
                saltHex: material.saltHex,
                deviceName: material.deviceName,
                otpAuthHex: material.otpAuthHex
            )
        )
        let serverCert = try responseParser.parse(serverCertResponse)
        guard serverCert.statusCode == 200, serverCert.isPaired, let plainCertificateHex = serverCert.plainCertificateHex else {
            throw MoonlightError(.pairingRejected, message: serverCert.statusMessage ?? "Pairing failed at getservercert")
        }

        try machine.advance(to: .clientChallenge)
        let challengeResponseData = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.clientChallengeQuery(
                uniqueID: material.uniqueID,
                challengeHex: material.clientChallengeHex
            )
        )
        let challengeResponse = try responseParser.parse(challengeResponseData)
        guard challengeResponse.statusCode == 200, challengeResponse.isPaired, let challengeResponseHex = challengeResponse.challengeResponseHex else {
            throw MoonlightError(.pairingRejected, message: challengeResponse.statusMessage ?? "Pairing failed at clientchallenge")
        }

        try machine.advance(to: .serverChallengeResponse)
        let pairingSecretResponseData = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.serverChallengeResponseQuery(
                uniqueID: material.uniqueID,
                responseHex: material.serverChallengeResponseHex
            )
        )
        let pairingSecretResponse = try responseParser.parse(pairingSecretResponseData)
        guard pairingSecretResponse.statusCode == 200, pairingSecretResponse.isPaired, let pairingSecretHex = pairingSecretResponse.pairingSecretHex else {
            throw MoonlightError(.pairingRejected, message: pairingSecretResponse.statusMessage ?? "Pairing failed at serverchallengeresp")
        }

        try machine.advance(to: .clientPairingSecret)
        let finalResponseData = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.clientPairingSecretQuery(
                uniqueID: material.uniqueID,
                secretHex: material.clientPairingSecretHex
            )
        )
        let finalResponse = try responseParser.parse(finalResponseData)
        guard finalResponse.statusCode == 200, finalResponse.isPaired else {
            throw MoonlightError(.pairingRejected, message: finalResponse.statusMessage ?? "Pairing failed at clientpairingsecret")
        }

        try machine.advance(to: .completed)
        return PairingExchange(
            serverCertificateHex: plainCertificateHex,
            challengeResponseHex: challengeResponseHex,
            pairingSecretHex: pairingSecretHex
        )
    }
}
