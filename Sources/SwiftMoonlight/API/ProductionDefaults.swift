import Foundation

public struct SystemClock: Clock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

public struct DefaultLogger: MoonlightLogger {
    public init() {}

    public func debug(_ message: String) {
        print("[swift-moonlight][debug] \(message)")
    }

    public func info(_ message: String) {
        print("[swift-moonlight][info] \(message)")
    }

    public func warning(_ message: String) {
        print("[swift-moonlight][warning] \(message)")
    }

    public func error(_ message: String) {
        fputs("[swift-moonlight][error] \(message)\n", stderr)
    }
}

public struct NoopMetricsSink: MetricsSink {
    public init() {}

    public func record(_ snapshot: SessionMetricsSnapshot) async {
        _ = snapshot
    }
}

public enum ProductionCredentialStorage: Sendable, Equatable {
    case files
    case keychain(KeychainCredentialConfiguration)
}

public enum ProductionClientFactory {
    public static func configuration(
        storageDirectory: URL,
        displayName: String = "swift-moonlight",
        logger: any MoonlightLogger = DefaultLogger(),
        metricsSink: any MetricsSink = NoopMetricsSink(),
        enableDiscovery: Bool = true,
        credentialStorage: ProductionCredentialStorage = .files,
        httpClient: (any HTTPClient)? = nil
    ) throws -> MoonlightClientConfiguration {
        let hostStore = FileHostStore(fileURL: storageDirectory.appending(path: "hosts.json"))
        let identityStore: any IdentityStore
        let pairingIdentityStore: any RSAPairingIdentityStore
        switch credentialStorage {
        case .files:
            identityStore = FileIdentityStore(
                fileURL: storageDirectory.appending(path: "identity.json"),
                defaultDisplayName: displayName
            )
            pairingIdentityStore = FileRSAPairingIdentityStore(
                fileURL: storageDirectory.appending(path: "pairing-identity.json")
            )
        case .keychain(let keychainConfiguration):
            identityStore = KeychainIdentityStore(
                configuration: keychainConfiguration,
                defaultDisplayName: displayName
            )
            pairingIdentityStore = KeychainRSAPairingIdentityStore(
                configuration: keychainConfiguration
            )
        }
        return configuration(
            hostStore: hostStore,
            identityStore: identityStore,
            pairingIdentityStore: pairingIdentityStore,
            logger: logger,
            metricsSink: metricsSink,
            enableDiscovery: enableDiscovery,
            httpClient: httpClient
        )
    }

    public static func configuration(
        hostStore: any HostStore,
        identityStore: any IdentityStore,
        pairingIdentityStore: (any RSAPairingIdentityStore)? = nil,
        logger: any MoonlightLogger = DefaultLogger(),
        metricsSink: any MetricsSink = NoopMetricsSink(),
        enableDiscovery: Bool = true,
        httpClient: (any HTTPClient)? = nil
    ) -> MoonlightClientConfiguration {
        let resolvedPairingIdentityStore = pairingIdentityStore ?? EphemeralRSAPairingIdentityStore()
        let client = httpClient ?? URLSessionHTTPClient(
            httpsClientIdentityProvider: {
                let identity = try await identityStore.loadOrCreateIdentity()
                let material = try resolvedPairingIdentityStore.loadOrCreateIdentityMaterial(for: identity)
                return HTTPSClientIdentityMaterial(
                    certificatePEM: material.certificatePEM,
                    privateKeyPEM: pemEncode(label: "RSA PRIVATE KEY", der: material.privateKeyData)
                )
            }
        )
        let hostService = HTTPHostService(client: client, identityStore: identityStore)
        let launchService = LaunchSessionService(
            transport: HTTPLaunchTransport(client: client),
            queryOptionsProvider: defaultLaunchQueryOptions(host:configuration:identity:)
        )
        let cryptoProvider = GeneratedRSAPairingCryptoProvider(
            identityStore: resolvedPairingIdentityStore
        )
        let pairingService = CryptoPairingClientService(
            transport: HTTPPairingTransport(client: client),
            cryptoProvider: cryptoProvider
        )
        #if canImport(Network)
        let rtspTransport = NetworkRTSPTransport()
        #else
        fatalError("Network framework is required for production RTSP transport")
        #endif
        let bootstrap = SessionBootstrap(
            launchService: launchService,
            rtspService: RTSPNegotiationService(transport: rtspTransport),
            channelService: ChannelEstablishmentService(transport: UDPChannelTransport())
        )

        return MoonlightClientConfiguration(
            hostStore: hostStore,
            hostDiscovery: enableDiscovery ? BonjourHostDiscovery() : nil,
            identityStore: identityStore,
            clock: SystemClock(),
            logger: logger,
            metricsSink: metricsSink,
            hostService: hostService,
            sessionService: launchService,
            pairingService: pairingService,
            sessionBootstrapService: bootstrap
        )
    }

    private static func defaultLaunchQueryOptions(
        host: MoonlightHost,
        configuration: StreamConfiguration,
        identity: ClientIdentity
    ) throws -> LaunchQueryOptions {
        _ = configuration
        _ = identity

        let keyData = try SystemRandomByteGenerator().generate(count: 16)
        let keyID = UInt32.random(in: 1...UInt32.max)
        return LaunchQueryOptions(
            remoteInputKeyHex: keyData.hexString,
            remoteInputKeyID: keyID,
            localAudioPlayMode: configuration.playAudioOnHost,
            gameControllerMapping: configuration.attachedGamepadMask,
            remoteControllersBitmap: configuration.attachedGamepadMask,
            persistGamepadsAfterDisconnect: configuration.persistGamepadsAfterDisconnect,
            continuousAudio: configuration.requestContinuousAudio,
            virtualDisplay: host.compatibilityProfile.quirks.contains(.apolloVirtualDisplayModes)
        )
    }

    private static func pemEncode(label: String, der: Data) -> String {
        let base64 = der.base64EncodedString()
        let body = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.count - offset))
            return String(base64[start..<end])
        }.joined(separator: "\n")
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }
}
