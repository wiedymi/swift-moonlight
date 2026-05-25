import Foundation

public struct HDRLaunchCapabilities: Sendable, Equatable {
    public var version: Int
    public var supportedFlags: UInt32
    public var metadataID: String
    public var displayData: String

    public init(
        version: Int,
        supportedFlags: UInt32,
        metadataID: String,
        displayData: String
    ) {
        self.version = version
        self.supportedFlags = supportedFlags
        self.metadataID = metadataID
        self.displayData = displayData
    }

    public static let staticMetadataType1Placeholder = HDRLaunchCapabilities(
        version: 0,
        supportedFlags: 0,
        metadataID: "NV_STATIC_METADATA_TYPE_1",
        displayData: "0x0x0x0x0x0x0x0x0x0x0"
    )
}

public struct LaunchQueryOptions: Sendable, Equatable {
    public var remoteInputKeyHex: String
    public var remoteInputKeyID: UInt32
    public var localAudioPlayMode: Bool
    public var coreVersion: Int
    public var enableSops: Bool
    public var gameControllerMapping: Int
    public var remoteControllersBitmap: Int
    public var persistGamepadsAfterDisconnect: Bool
    public var continuousAudio: Bool
    public var virtualDisplay: Bool
    public var scaleFactor: Int
    public var hdrCapabilities: HDRLaunchCapabilities?

    public init(
        remoteInputKeyHex: String,
        remoteInputKeyID: UInt32,
        localAudioPlayMode: Bool = false,
        coreVersion: Int = 1,
        enableSops: Bool = true,
        gameControllerMapping: Int = 0,
        remoteControllersBitmap: Int = 0,
        persistGamepadsAfterDisconnect: Bool = false,
        continuousAudio: Bool = false,
        virtualDisplay: Bool = false,
        scaleFactor: Int = 100,
        hdrCapabilities: HDRLaunchCapabilities? = .staticMetadataType1Placeholder
    ) {
        self.remoteInputKeyHex = remoteInputKeyHex
        self.remoteInputKeyID = remoteInputKeyID
        self.localAudioPlayMode = localAudioPlayMode
        self.coreVersion = coreVersion
        self.enableSops = enableSops
        self.gameControllerMapping = gameControllerMapping
        self.remoteControllersBitmap = remoteControllersBitmap
        self.persistGamepadsAfterDisconnect = persistGamepadsAfterDisconnect
        self.continuousAudio = continuousAudio
        self.virtualDisplay = virtualDisplay
        self.scaleFactor = scaleFactor
        self.hdrCapabilities = hdrCapabilities
    }
}

public struct LaunchQueryBuilder: Sendable {
    public init() {}

    public func buildLaunchQuery(
        host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        identity: ClientIdentity,
        options: LaunchQueryOptions
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            .init(name: "uniqueid", value: identity.identifier.uuidString.lowercased()),
            .init(name: "appid", value: appID),
            .init(name: "mode", value: modeString(configuration)),
            .init(name: "additionalStates", value: "1"),
            .init(name: "sops", value: boolNumber(options.enableSops)),
            .init(name: "rikey", value: options.remoteInputKeyHex.lowercased()),
            .init(name: "rikeyid", value: String(options.remoteInputKeyID)),
            .init(name: "localAudioPlayMode", value: boolNumber(options.localAudioPlayMode)),
            .init(name: "surroundAudioInfo", value: surroundAudioInfo(configuration.audioMode)),
            .init(name: "remoteControllersBitmap", value: String(options.remoteControllersBitmap)),
            .init(name: "gcmap", value: String(options.gameControllerMapping)),
            .init(name: "gcpersist", value: boolNumber(options.persistGamepadsAfterDisconnect)),
            .init(name: "hdrMode", value: boolNumber(configuration.dynamicRange == .hdr)),
            .init(name: "corever", value: String(options.coreVersion)),
        ]

        if configuration.dynamicRange == .hdr, let hdrCapabilities = options.hdrCapabilities {
            items.append(contentsOf: hdrCapabilityItems(hdrCapabilities))
        }

        if options.continuousAudio {
            items.append(.init(name: "continuousAudio", value: "1"))
        }

        if host.kind == .apollo {
            items.append(.init(name: "scaleFactor", value: String(options.scaleFactor)))
            if options.virtualDisplay {
                items.append(.init(name: "virtualDisplay", value: "1"))
            }
        }

        return items
    }

    private func modeString(_ configuration: StreamConfiguration) -> String {
        let width = Int(configuration.resolution.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(configuration.resolution.height.rounded(.toNearestOrAwayFromZero))
        return "\(width)x\(height)x\(configuration.frameRate)"
    }

    private func surroundAudioInfo(_ audioMode: AudioMode) -> String {
        switch audioMode {
        case .stereo:
            return String((0x3 << 16) | 2)
        case .surround51:
            return String((0x3F << 16) | 6)
        case .surround71:
            return String((0x63F << 16) | 8)
        }
    }

    private func boolNumber(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    private func hdrCapabilityItems(_ capabilities: HDRLaunchCapabilities) -> [URLQueryItem] {
        [
            .init(name: "clientHdrCapVersion", value: String(capabilities.version)),
            .init(name: "clientHdrCapSupportedFlagsInUint32", value: String(capabilities.supportedFlags)),
            .init(name: "clientHdrCapMetaDataId", value: capabilities.metadataID),
            .init(name: "clientHdrCapDisplayData", value: capabilities.displayData),
        ]
    }
}
