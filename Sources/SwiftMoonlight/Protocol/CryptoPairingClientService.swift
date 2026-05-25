import CryptoKit
import Foundation

public protocol PairingCryptoProvider: Sendable {
    func identityMaterial(for identity: ClientIdentity) throws -> PairingIdentityMaterial
    func signClientSecret(_ clientSecret: Data, for identity: ClientIdentity) throws -> Data
    func serverCertificateSignature(certificateHex: String) throws -> Data
    func verifyServerSignature(secret: Data, signature: Data, certificateHex: String) throws -> Bool
}

public struct DigestPairingCryptoProvider: PairingCryptoProvider {
    public init() {}

    public func identityMaterial(for identity: ClientIdentity) throws -> PairingIdentityMaterial {
        let certData = Data("client-cert:\(identity.identifier.uuidString.lowercased()):\(identity.displayName)".utf8)
        let signature = Data(SHA256.hash(data: certData))
        return PairingIdentityMaterial(
            clientCertificateHex: certData.hexString,
            certificateSignature: signature
        )
    }

    public func signClientSecret(_ clientSecret: Data, for identity: ClientIdentity) throws -> Data {
        let seed = Data("client-sign:\(identity.identifier.uuidString.lowercased())".utf8)
        return Data(SHA256.hash(data: seed + clientSecret))
    }

    public func serverCertificateSignature(certificateHex: String) throws -> Data {
        let certificate = try Data(hexString: certificateHex)
        return Data(SHA256.hash(data: certificate))
    }

    public func verifyServerSignature(secret: Data, signature: Data, certificateHex: String) throws -> Bool {
        let expected = try Data(
            hexString: certificateHex
        )
        return Data(SHA256.hash(data: expected + secret)) == signature
    }
}

public struct CryptoPairingClientService: PairingClientService, Sendable {
    public let transport: any PairingTransport
    public let requestBuilder: PairingRequestBuilder
    public let responseParser: PairingResponseParser
    public let materialFactory: PairingMaterialFactory
    public let cryptoProvider: any PairingCryptoProvider
    public let performPairChallengeVerification: Bool

    public init(
        transport: any PairingTransport,
        requestBuilder: PairingRequestBuilder = PairingRequestBuilder(),
        responseParser: PairingResponseParser = PairingResponseParser(),
        materialFactory: PairingMaterialFactory = PairingMaterialFactory(),
        cryptoProvider: any PairingCryptoProvider,
        performPairChallengeVerification: Bool = true
    ) {
        self.transport = transport
        self.requestBuilder = requestBuilder
        self.responseParser = responseParser
        self.materialFactory = materialFactory
        self.cryptoProvider = cryptoProvider
        self.performPairChallengeVerification = performPairChallengeVerification
    }

    public func pair(host: MoonlightHost, auth: PairingAuth, identity: ClientIdentity) async throws -> PairingResult {
        let algorithm = PairingHashAlgorithm(serverMajorVersion: serverMajorVersion(for: host))
        let identityMaterial = try cryptoProvider.identityMaterial(for: identity)
        let prepared = try materialFactory.prepare(
            pin: auth.pin,
            serverMajorVersion: serverMajorVersion(for: host),
            identity: identityMaterial,
            uniqueID: identity.identifier,
            deviceName: identity.displayName
        )
        let otpAuthHex = makeOTPAuthHex(auth: auth, saltHex: prepared.salt.hexString)

        let serverCertResponseData = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.getServerCertQuery(
                host: host,
                uniqueID: prepared.uniqueID,
                clientCertificateHex: prepared.clientCertificateHex,
                saltHex: prepared.salt.hexString,
                deviceName: prepared.deviceName,
                otpAuthHex: otpAuthHex
            )
        )
        let serverCertResponse = try responseParser.parse(serverCertResponseData)
        guard serverCertResponse.statusCode == 200,
              serverCertResponse.isPaired,
              let plainCertificateHex = serverCertResponse.plainCertificateHex
        else {
            throw MoonlightError(.pairingRejected, message: serverCertResponse.statusMessage ?? "Pairing failed at getservercert")
        }

        let clientChallengeResponseData = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.clientChallengeQuery(
                uniqueID: prepared.uniqueID,
                challengeHex: prepared.encryptedClientChallenge.hexString
            )
        )
        let clientChallengeResponse = try responseParser.parse(clientChallengeResponseData)
        guard clientChallengeResponse.statusCode == 200,
              clientChallengeResponse.isPaired,
              let encryptedServerChallengeResponseHex = clientChallengeResponse.challengeResponseHex
        else {
            throw MoonlightError(.pairingRejected, message: clientChallengeResponse.statusMessage ?? "Pairing failed at clientchallenge")
        }

        let encryptedServerChallengeResponse = try Data(hexString: encryptedServerChallengeResponseHex)
        let decoded = try PairingCrypto.decodeServerChallengeResponse(
            encryptedServerChallengeResponse,
            key: prepared.aesKey,
            algorithm: algorithm
        )

        let serverChallengeResponseHex = try PairingCrypto.encryptServerChallengeResponse(
            serverChallenge: decoded.serverChallenge,
            clientCertificateSignature: identityMaterial.certificateSignature,
            clientSecret: prepared.clientSecret,
            aesKey: prepared.aesKey,
            algorithm: algorithm
        ).hexString

        let pairingSecretResponseData = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.serverChallengeResponseQuery(
                uniqueID: prepared.uniqueID,
                responseHex: serverChallengeResponseHex
            )
        )
        let pairingSecretResponse = try responseParser.parse(pairingSecretResponseData)
        guard pairingSecretResponse.statusCode == 200,
              pairingSecretResponse.isPaired,
              let pairingSecretHex = pairingSecretResponse.pairingSecretHex
        else {
            throw MoonlightError(.pairingRejected, message: pairingSecretResponse.statusMessage ?? "Pairing failed at serverchallengeresp")
        }

        let serverPairingSecret = try Data(hexString: pairingSecretHex)
        let splitSecret = try PairingCrypto.splitServerPairingSecret(serverPairingSecret)
        let serverSecretSignatureIsValid = try cryptoProvider.verifyServerSignature(
            secret: splitSecret.secret,
            signature: splitSecret.signature,
            certificateHex: plainCertificateHex
        )
        guard serverSecretSignatureIsValid else {
            throw MoonlightError(.pairingRejected, message: "Server certificate invalid")
        }

        let serverCertificateSignature = try cryptoProvider.serverCertificateSignature(certificateHex: plainCertificateHex)
        guard PairingCrypto.validateServerResponse(
            serverResponse: decoded.serverResponse,
            randomChallenge: prepared.randomChallenge,
            serverCertificateSignature: serverCertificateSignature,
            serverSecret: splitSecret.secret,
            algorithm: algorithm
        ) else {
            throw MoonlightError(.pairingRejected, message: "Incorrect PIN")
        }

        let clientPairingSecretHex = try materialFactory.clientPairingSecretHex(
            clientSecret: prepared.clientSecret,
            signer: PairingSignerAdapter(identity: identity, provider: cryptoProvider)
        )

        let finalResponseData = try await transport.sendPairingRequest(
            to: host,
            queryItems: requestBuilder.clientPairingSecretQuery(
                uniqueID: prepared.uniqueID,
                secretHex: clientPairingSecretHex
            )
        )
        let finalResponse = try responseParser.parse(finalResponseData)
        guard finalResponse.statusCode == 200, finalResponse.isPaired else {
            throw MoonlightError(.pairingRejected, message: finalResponse.statusMessage ?? "Pairing failed at clientpairingsecret")
        }

        if performPairChallengeVerification {
            let verificationData = try await transport.sendPairingRequest(
                to: host,
                queryItems: requestBuilder.pairChallengeQuery(uniqueID: prepared.uniqueID)
            )
            let verificationResponse = try responseParser.parse(verificationData)
            guard verificationResponse.statusCode == 200, verificationResponse.isPaired else {
                throw MoonlightError(.pairingRejected, message: verificationResponse.statusMessage ?? "Pairing failed at pairchallenge")
            }
        }

        return PairingResult(hostID: host.id, state: .paired)
    }

    public func unpair(host: MoonlightHost, identity: ClientIdentity) async throws {
        _ = try await transport.sendUnpairRequest(
            to: host,
            queryItems: requestBuilder.unpairQuery(uniqueID: identity.identifier)
        )
    }

    private func serverMajorVersion(for host: MoonlightHost) -> Int {
        switch host.kind {
        case .sunshine, .apollo:
            return 7
        case .unknown:
            return 7
        }
    }

    private func makeOTPAuthHex(auth: PairingAuth, saltHex: String) -> String? {
        guard case .otp(let pin, let passphrase) = auth else {
            return nil
        }
        let payload = Data((pin + saltHex.lowercased() + passphrase).utf8)
        return Data(SHA256.hash(data: payload)).hexString
    }
}

private struct PairingSignerAdapter: PairingSigning {
    let identity: ClientIdentity
    let provider: any PairingCryptoProvider

    func sign(_ data: Data) throws -> Data {
        try provider.signClientSecret(data, for: identity)
    }
}
