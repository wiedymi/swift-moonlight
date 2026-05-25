import Foundation

public actor FileHostStore: HostStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func debugFilePath() -> String {
        fileURL.fileSystemPath
    }

    public func loadHosts() async throws -> [MoonlightHost] {
        guard FileManager.default.fileExists(atPath: fileURL.fileSystemPath) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let persisted = try decoder.decode([PersistedMoonlightHost].self, from: data)
        return persisted.map(\.host)
    }

    public func saveHosts(_ hosts: [MoonlightHost]) async throws {
        let persisted = hosts.map(PersistedMoonlightHost.init(host:))
        let data = try encoder.encode(persisted)
        try writeAtomically(data, to: fileURL)
    }
}

private struct PersistedMoonlightHost: Codable {
    let id: UUID
    let name: String
    let endpointAddress: String
    let endpointPort: Int
    let endpointSecurePort: Int?
    let kind: String
    let pairingState: String
    let capabilities: PersistedHostCapabilities
    let quirks: [String]

    init(host: MoonlightHost) {
        id = host.id.rawValue
        name = host.name
        endpointAddress = host.endpoint.address
        endpointPort = host.endpoint.port
        endpointSecurePort = host.endpoint.securePort
        kind = switch host.kind {
        case .sunshine: "sunshine"
        case .apollo: "apollo"
        case .unknown: "unknown"
        }
        pairingState = switch host.pairingState {
        case .unpaired: "unpaired"
        case .paired: "paired"
        case .unknown: "unknown"
        }
        capabilities = PersistedHostCapabilities(capabilities: host.capabilities)
        quirks = host.compatibilityProfile.quirks.values.map(\.rawValue).sorted()
    }

    var host: MoonlightHost {
        let hostKind = switch kind {
        case "sunshine": HostKind.sunshine
        case "apollo": HostKind.apollo
        default: HostKind.unknown
        }
        let state = switch pairingState {
        case "unpaired": PairingState.unpaired
        case "paired": PairingState.paired
        default: PairingState.unknown
        }
        let quirkSet = HostQuirkSet(Set(quirks.compactMap(HostQuirk.init(rawValue:))))
        return MoonlightHost(
            id: HostID(rawValue: id),
            name: name,
            endpoint: HostEndpoint(address: endpointAddress, port: endpointPort, securePort: endpointSecurePort),
            kind: hostKind,
            pairingState: state,
            capabilities: capabilities.value,
            compatibilityProfile: HostCompatibilityProfile(kind: hostKind, quirks: quirkSet)
        )
    }
}

private struct PersistedHostCapabilities: Codable {
    let supportsControllerInput: Bool
    let supportsTouchInput: Bool
    let supportsHardwareDecode: Bool
    let supportsSoftwareDecodeFallback: Bool
    let supportsInputOnlySession: Bool
    let supportsOTPAuth: Bool
    let requiresPerClientAuthorization: Bool
    let supportedVideoCodecs: [String]
    let supportsHDR: Bool

    init(capabilities: HostCapabilities) {
        supportsControllerInput = capabilities.supportsControllerInput
        supportsTouchInput = capabilities.supportsTouchInput
        supportsHardwareDecode = capabilities.supportsHardwareDecode
        supportsSoftwareDecodeFallback = capabilities.supportsSoftwareDecodeFallback
        supportsInputOnlySession = capabilities.supportsInputOnlySession
        supportsOTPAuth = capabilities.supportsOTPAuth
        requiresPerClientAuthorization = capabilities.requiresPerClientAuthorization
        supportedVideoCodecs = capabilities.supportedVideoCodecs.map(Self.persistedName(for:))
        supportsHDR = capabilities.supportsHDR
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsControllerInput = try container.decode(Bool.self, forKey: .supportsControllerInput)
        supportsTouchInput = try container.decode(Bool.self, forKey: .supportsTouchInput)
        supportsHardwareDecode = try container.decode(Bool.self, forKey: .supportsHardwareDecode)
        supportsSoftwareDecodeFallback = try container.decode(Bool.self, forKey: .supportsSoftwareDecodeFallback)
        supportsInputOnlySession = try container.decode(Bool.self, forKey: .supportsInputOnlySession)
        supportsOTPAuth = try container.decode(Bool.self, forKey: .supportsOTPAuth)
        requiresPerClientAuthorization = try container.decode(Bool.self, forKey: .requiresPerClientAuthorization)
        supportedVideoCodecs = try container.decodeIfPresent([String].self, forKey: .supportedVideoCodecs)
            ?? HostCapabilities.default.supportedVideoCodecs.map(Self.persistedName(for:))
        supportsHDR = try container.decodeIfPresent(Bool.self, forKey: .supportsHDR) ?? false
    }

    var value: HostCapabilities {
        let restoredCodecs = supportedVideoCodecs.compactMap(Self.videoCodec(for:))
        return HostCapabilities(
            supportsControllerInput: supportsControllerInput,
            supportsTouchInput: supportsTouchInput,
            supportsHardwareDecode: supportsHardwareDecode,
            supportsSoftwareDecodeFallback: supportsSoftwareDecodeFallback,
            supportsInputOnlySession: supportsInputOnlySession,
            supportsOTPAuth: supportsOTPAuth,
            requiresPerClientAuthorization: requiresPerClientAuthorization,
            supportedVideoCodecs: restoredCodecs.isEmpty ? HostCapabilities.default.supportedVideoCodecs : restoredCodecs,
            supportsHDR: supportsHDR
        )
    }

    private static func persistedName(for codec: VideoCodec) -> String {
        switch codec {
        case .h264:
            return "h264"
        case .hevc:
            return "hevc"
        case .av1:
            return "av1"
        }
    }

    private static func videoCodec(for persistedName: String) -> VideoCodec? {
        switch persistedName {
        case "h264":
            return .h264
        case "hevc":
            return .hevc
        case "av1":
            return .av1
        default:
            return nil
        }
    }
}

func writeAtomically(_ data: Data, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
}

private extension URL {
    var fileSystemPath: String {
        path(percentEncoded: false)
    }
}
