import Foundation

public struct PairingRequestBuilder: Sendable {
    public init() {}

    public func getServerCertQuery(
        host: MoonlightHost,
        uniqueID: UUID,
        clientCertificateHex: String,
        saltHex: String,
        deviceName: String?,
        otpAuthHex: String? = nil
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            .init(name: "devicename", value: pairingDeviceName(for: host, requestedDeviceName: deviceName)),
            .init(name: "updateState", value: "1"),
            .init(name: "uniqueid", value: uniqueID.uuidString.lowercased()),
            .init(name: "phrase", value: "getservercert"),
            .init(name: "clientcert", value: clientCertificateHex.lowercased()),
            .init(name: "salt", value: saltHex.lowercased()),
        ]

        if host.kind == .apollo {
            if let otpAuthHex {
                items.append(.init(name: "otpauth", value: otpAuthHex.lowercased()))
            }
        }

        return items
    }

    public func pairChallengeQuery(uniqueID: UUID) -> [URLQueryItem] {
        [
            .init(name: "devicename", value: "roth"),
            .init(name: "updateState", value: "1"),
            .init(name: "uniqueid", value: uniqueID.uuidString.lowercased()),
            .init(name: "phrase", value: "pairchallenge"),
        ]
    }

    public func clientChallengeQuery(uniqueID: UUID, challengeHex: String) -> [URLQueryItem] {
        [
            .init(name: "devicename", value: "roth"),
            .init(name: "updateState", value: "1"),
            .init(name: "uniqueid", value: uniqueID.uuidString.lowercased()),
            .init(name: "clientchallenge", value: challengeHex.lowercased()),
        ]
    }

    public func serverChallengeResponseQuery(uniqueID: UUID, responseHex: String) -> [URLQueryItem] {
        [
            .init(name: "devicename", value: "roth"),
            .init(name: "updateState", value: "1"),
            .init(name: "uniqueid", value: uniqueID.uuidString.lowercased()),
            .init(name: "serverchallengeresp", value: responseHex.lowercased()),
        ]
    }

    public func clientPairingSecretQuery(uniqueID: UUID, secretHex: String) -> [URLQueryItem] {
        [
            .init(name: "devicename", value: "roth"),
            .init(name: "updateState", value: "1"),
            .init(name: "uniqueid", value: uniqueID.uuidString.lowercased()),
            .init(name: "clientpairingsecret", value: secretHex.lowercased()),
        ]
    }

    public func unpairQuery(uniqueID: UUID) -> [URLQueryItem] {
        [
            .init(name: "uniqueid", value: uniqueID.uuidString.lowercased()),
        ]
    }

    private func pairingDeviceName(for host: MoonlightHost, requestedDeviceName: String?) -> String {
        if host.kind == .apollo, let requestedDeviceName, !requestedDeviceName.isEmpty {
            return requestedDeviceName
        }
        // Existing Moonlight clients use "roth" here as a compatibility marker.
        return "roth"
    }
}

public struct PairingResponse: Sendable, Equatable {
    public var statusCode: Int
    public var statusMessage: String?
    public var isPaired: Bool
    public var plainCertificateHex: String?
    public var challengeResponseHex: String?
    public var pairingSecretHex: String?

    public init(
        statusCode: Int,
        statusMessage: String?,
        isPaired: Bool,
        plainCertificateHex: String? = nil,
        challengeResponseHex: String? = nil,
        pairingSecretHex: String? = nil
    ) {
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.isPaired = isPaired
        self.plainCertificateHex = plainCertificateHex
        self.challengeResponseHex = challengeResponseHex
        self.pairingSecretHex = pairingSecretHex
    }
}

public struct PairingResponseParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> PairingResponse {
        let document = try XMLScalarDocument(data: data)

        guard let statusCodeText = document.attribute(named: "status_code", onElementNamed: "root"),
              let statusCode = Int(statusCodeText)
        else {
            throw MoonlightError(.pairingRejected, message: "Pairing response is missing status_code")
        }

        let isPaired = document.firstValue(forElementNamed: "paired") == "1"
        return PairingResponse(
            statusCode: statusCode,
            statusMessage: document.attribute(named: "status_message", onElementNamed: "root"),
            isPaired: isPaired,
            plainCertificateHex: document.firstValue(forElementNamed: "plaincert"),
            challengeResponseHex: document.firstValue(forElementNamed: "challengeresponse"),
            pairingSecretHex: document.firstValue(forElementNamed: "pairingsecret")
        )
    }
}

public struct PairingMaterial: Sendable, Equatable {
    public var uniqueID: UUID
    public var clientCertificateHex: String
    public var saltHex: String
    public var clientChallengeHex: String
    public var serverChallengeResponseHex: String
    public var clientPairingSecretHex: String
    public var deviceName: String?
    public var otpAuthHex: String?

    public init(
        uniqueID: UUID,
        clientCertificateHex: String,
        saltHex: String,
        clientChallengeHex: String,
        serverChallengeResponseHex: String,
        clientPairingSecretHex: String,
        deviceName: String? = nil,
        otpAuthHex: String? = nil
    ) {
        self.uniqueID = uniqueID
        self.clientCertificateHex = clientCertificateHex
        self.saltHex = saltHex
        self.clientChallengeHex = clientChallengeHex
        self.serverChallengeResponseHex = serverChallengeResponseHex
        self.clientPairingSecretHex = clientPairingSecretHex
        self.deviceName = deviceName
        self.otpAuthHex = otpAuthHex
    }
}

public struct PairingExchange: Sendable, Equatable {
    public var serverCertificateHex: String
    public var challengeResponseHex: String
    public var pairingSecretHex: String

    public init(serverCertificateHex: String, challengeResponseHex: String, pairingSecretHex: String) {
        self.serverCertificateHex = serverCertificateHex
        self.challengeResponseHex = challengeResponseHex
        self.pairingSecretHex = pairingSecretHex
    }
}
