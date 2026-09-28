import CoreGraphics
import Foundation

public struct HostID: Hashable, Equatable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct HostEndpoint: Equatable, Sendable {
    public var address: String
    public var port: Int
    public var securePort: Int?

    public init(address: String, port: Int, securePort: Int? = nil) {
        self.address = address
        self.port = port
        self.securePort = securePort
    }
}

public enum HostKind: Equatable, Sendable {
    case sunshine
    case apollo
    case unknown
}

public enum HostQuirk: String, Sendable, Equatable, Hashable, CaseIterable {
    case apolloPerClientPermissions
    case apolloOTPAuth
    case apolloInputOnlySession
    case apolloVirtualDisplayModes
    case apolloInputPermissionGating
    case apolloTouchCoordinateTransform
}

public struct HostQuirkSet: Sendable, Equatable {
    public var values: Set<HostQuirk>

    public init(_ values: Set<HostQuirk> = []) {
        self.values = values
    }

    public func contains(_ quirk: HostQuirk) -> Bool {
        values.contains(quirk)
    }

    public static func `for`(_ kind: HostKind) -> HostQuirkSet {
        switch kind {
        case .sunshine:
            return HostQuirkSet()
        case .apollo:
            return HostQuirkSet([
                .apolloPerClientPermissions,
                .apolloOTPAuth,
                .apolloInputOnlySession,
                .apolloVirtualDisplayModes,
                .apolloInputPermissionGating,
                .apolloTouchCoordinateTransform,
            ])
        case .unknown:
            return HostQuirkSet()
        }
    }
}

public struct HostCompatibilityProfile: Sendable, Equatable {
    public var kind: HostKind
    public var quirks: HostQuirkSet

    public init(kind: HostKind, quirks: HostQuirkSet) {
        self.kind = kind
        self.quirks = quirks
    }

    public static func `for`(_ kind: HostKind) -> HostCompatibilityProfile {
        HostCompatibilityProfile(kind: kind, quirks: .for(kind))
    }
}

public enum PairingState: Equatable, Sendable {
    case unpaired
    case paired
    case unknown

    public var isPaired: Bool {
        self == .paired
    }
}

public struct HostCapabilities: Equatable, Sendable {
    private static let scmH264: UInt32 = 0x0000_0001
    private static let scmHEVC: UInt32 = 0x0000_0100
    private static let scmHEVCMain10: UInt32 = 0x0000_0200
    private static let scmAV1Main8: UInt32 = 0x0001_0000
    private static let scmAV1Main10: UInt32 = 0x0002_0000
    private static let scmH264High444: UInt32 = 0x0004_0000
    private static let scmHEVCRExt8444: UInt32 = 0x0008_0000
    private static let scmHEVCRExt10444: UInt32 = 0x0010_0000
    private static let scmAV1High8444: UInt32 = 0x0020_0000
    private static let scmAV1High10444: UInt32 = 0x0040_0000

    private static let scmMaskH264 = scmH264 | scmH264High444
    private static let scmMaskHEVC = scmHEVC | scmHEVCMain10 | scmHEVCRExt8444 | scmHEVCRExt10444
    private static let scmMaskAV1 = scmAV1Main8 | scmAV1Main10 | scmAV1High8444 | scmAV1High10444
    private static let scmMaskHDR = scmHEVCMain10 | scmAV1Main10

    public var supportsControllerInput: Bool
    public var supportsTouchInput: Bool
    public var supportsHardwareDecode: Bool
    public var supportsSoftwareDecodeFallback: Bool
    public var supportsInputOnlySession: Bool
    public var supportsOTPAuth: Bool
    public var requiresPerClientAuthorization: Bool
    public var supportedVideoCodecs: [VideoCodec]
    public var supportsHDR: Bool

    public init(
        supportsControllerInput: Bool = true,
        supportsTouchInput: Bool = true,
        supportsHardwareDecode: Bool = true,
        supportsSoftwareDecodeFallback: Bool = true,
        supportsInputOnlySession: Bool = false,
        supportsOTPAuth: Bool = false,
        requiresPerClientAuthorization: Bool = false,
        supportedVideoCodecs: [VideoCodec] = [.hevc, .h264],
        supportsHDR: Bool = false
    ) {
        self.supportsControllerInput = supportsControllerInput
        self.supportsTouchInput = supportsTouchInput
        self.supportsHardwareDecode = supportsHardwareDecode
        self.supportsSoftwareDecodeFallback = supportsSoftwareDecodeFallback
        self.supportsInputOnlySession = supportsInputOnlySession
        self.supportsOTPAuth = supportsOTPAuth
        self.requiresPerClientAuthorization = requiresPerClientAuthorization
        self.supportedVideoCodecs = supportedVideoCodecs
        self.supportsHDR = supportsHDR
    }

    public static let `default` = HostCapabilities()

    public static func inferred(for kind: HostKind, codecSupportFlags: UInt32) -> HostCapabilities {
        let supportedVideoCodecs = Self.supportedVideoCodecs(from: codecSupportFlags)
        let supportsHDR = (codecSupportFlags & scmMaskHDR) != 0
        switch kind {
        case .sunshine:
            return HostCapabilities(
                supportsControllerInput: true,
                supportsTouchInput: true,
                supportsHardwareDecode: true,
                supportsSoftwareDecodeFallback: true,
                supportsInputOnlySession: false,
                supportsOTPAuth: false,
                requiresPerClientAuthorization: false,
                supportedVideoCodecs: supportedVideoCodecs,
                supportsHDR: supportsHDR
            )
        case .apollo:
            return HostCapabilities(
                supportsControllerInput: true,
                supportsTouchInput: true,
                supportsHardwareDecode: true,
                supportsSoftwareDecodeFallback: true,
                supportsInputOnlySession: true,
                supportsOTPAuth: true,
                requiresPerClientAuthorization: true,
                supportedVideoCodecs: supportedVideoCodecs,
                supportsHDR: supportsHDR
            )
        case .unknown:
            return .default
        }
    }

    public func supports(_ codec: VideoCodec) -> Bool {
        supportedVideoCodecs.contains(codec)
    }

    private static func supportedVideoCodecs(from codecSupportFlags: UInt32) -> [VideoCodec] {
        guard codecSupportFlags != 0 else {
            return Self.default.supportedVideoCodecs
        }

        var codecs: [VideoCodec] = []
        if codecSupportFlags & scmMaskAV1 != 0 {
            codecs.append(.av1)
        }
        if codecSupportFlags & scmMaskHEVC != 0 {
            codecs.append(.hevc)
        }
        if codecSupportFlags & scmMaskH264 != 0 {
            codecs.append(.h264)
        }
        return codecs.isEmpty ? Self.default.supportedVideoCodecs : codecs
    }
}

public struct MoonlightHost: Identifiable, Equatable, Sendable {
    public var id: HostID
    public var name: String
    public var endpoint: HostEndpoint
    public var kind: HostKind
    public var pairingState: PairingState
    public var capabilities: HostCapabilities
    public var compatibilityProfile: HostCompatibilityProfile

    public init(
        id: HostID,
        name: String,
        endpoint: HostEndpoint,
        kind: HostKind,
        pairingState: PairingState,
        capabilities: HostCapabilities,
        compatibilityProfile: HostCompatibilityProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.kind = kind
        self.pairingState = pairingState
        self.capabilities = capabilities
        self.compatibilityProfile = compatibilityProfile ?? .for(kind)
    }
}

public struct DiscoveredHost: Equatable, Sendable {
    public var name: String
    public var endpoint: HostEndpoint

    public init(name: String, endpoint: HostEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }
}

public struct RemoteApp: Identifiable, Equatable, Sendable {
    public typealias ID = String

    public var id: ID
    public var name: String
    public var supportsHDR: Bool

    public init(id: ID, name: String, supportsHDR: Bool = false) {
        self.id = id
        self.name = name
        self.supportsHDR = supportsHDR
    }
}
