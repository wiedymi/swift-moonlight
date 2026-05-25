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

public struct PairingResult: Equatable, Sendable {
    public var hostID: HostID
    public var state: PairingState

    public init(hostID: HostID, state: PairingState) {
        self.hostID = hostID
        self.state = state
    }
}

public enum PairingAuth: Equatable, Sendable {
    case pin(String)
    case otp(pin: String, passphrase: String)

    public var pin: String {
        switch self {
        case .pin(let pin), .otp(let pin, _):
            return pin
        }
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

public enum DynamicRangePreference: Equatable, Sendable {
    case sdr
    case hdr
}

public enum VideoCodec: Equatable, Sendable {
    case hevc
    case h264
    case av1
}

public enum AudioMode: Equatable, Sendable {
    case stereo
    case surround51
    case surround71

    public var channelCount: Int {
        switch self {
        case .stereo:
            return 2
        case .surround51:
            return 6
        case .surround71:
            return 8
        }
    }
}

public enum DecodeModePreference: Equatable, Sendable {
    case hardwareFirst
    case hardwareOnly
    case softwareFallback
}

public struct StreamConfiguration: Equatable, Sendable {
    public static let minimumResolution = CGSize(width: 320, height: 180)
    public static let maximumResolution = CGSize(width: 7680, height: 4320)
    public static let validFrameRateRange = 1...240
    public static let validBitrateKbpsRange = 1...500_000

    public var resolution: CGSize
    public var frameRate: Int
    public var bitrateKbps: Int
    public var dynamicRange: DynamicRangePreference
    public var videoCodecPreference: [VideoCodec]
    public var audioMode: AudioMode
    public var preferredDecodeMode: DecodeModePreference
    public var enableControlEncryption: Bool
    public var enableVideoEncryption: Bool
    public var enableAudioEncryption: Bool
    public var playAudioOnHost: Bool
    public var requestContinuousAudio: Bool
    public var attachedGamepadMask: Int
    public var persistGamepadsAfterDisconnect: Bool

    public init(
        resolution: CGSize,
        frameRate: Int,
        bitrateKbps: Int,
        dynamicRange: DynamicRangePreference,
        videoCodecPreference: [VideoCodec],
        audioMode: AudioMode,
        preferredDecodeMode: DecodeModePreference,
        enableControlEncryption: Bool = true,
        enableVideoEncryption: Bool = true,
        enableAudioEncryption: Bool = true,
        playAudioOnHost: Bool = false,
        requestContinuousAudio: Bool = false,
        attachedGamepadMask: Int = 0,
        persistGamepadsAfterDisconnect: Bool = false
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.bitrateKbps = bitrateKbps
        self.dynamicRange = dynamicRange
        self.videoCodecPreference = videoCodecPreference
        self.audioMode = audioMode
        self.preferredDecodeMode = preferredDecodeMode
        self.enableControlEncryption = enableControlEncryption
        self.enableVideoEncryption = enableVideoEncryption
        self.enableAudioEncryption = enableAudioEncryption
        self.playAudioOnHost = playAudioOnHost
        self.requestContinuousAudio = requestContinuousAudio
        self.attachedGamepadMask = attachedGamepadMask
        self.persistGamepadsAfterDisconnect = persistGamepadsAfterDisconnect
    }

    public static let default1080p60 = StreamConfiguration(
        resolution: CGSize(width: 1920, height: 1080),
        frameRate: 60,
        bitrateKbps: 20_000,
        dynamicRange: .sdr,
        videoCodecPreference: [.hevc, .h264],
        audioMode: .stereo,
        preferredDecodeMode: .hardwareFirst,
        enableControlEncryption: true,
        enableVideoEncryption: true,
        enableAudioEncryption: true
    )

    public func validate() throws {
        guard resolution.width.isFinite,
              resolution.height.isFinite,
              resolution.width >= Self.minimumResolution.width,
              resolution.height >= Self.minimumResolution.height,
              resolution.width <= Self.maximumResolution.width,
              resolution.height <= Self.maximumResolution.height
        else {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Stream resolution must be between \(Int(Self.minimumResolution.width))x\(Int(Self.minimumResolution.height)) and \(Int(Self.maximumResolution.width))x\(Int(Self.maximumResolution.height))"
            )
        }

        guard Self.validFrameRateRange.contains(frameRate) else {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Stream frame rate must be between \(Self.validFrameRateRange.lowerBound) and \(Self.validFrameRateRange.upperBound) FPS"
            )
        }

        guard Self.validBitrateKbpsRange.contains(bitrateKbps) else {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Stream bitrate must be between \(Self.validBitrateKbpsRange.lowerBound) and \(Self.validBitrateKbpsRange.upperBound) Kbps"
            )
        }

        guard !videoCodecPreference.isEmpty else {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Stream video codec preference must contain at least one codec"
            )
        }

        guard attachedGamepadMask >= 0 else {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Attached gamepad mask must not be negative"
            )
        }
    }

    public func validate(against host: MoonlightHost) throws {
        try validate()

        let supportedRequestedCodecs = videoCodecPreference.filter(host.capabilities.supports)
        guard !supportedRequestedCodecs.isEmpty else {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Host does not support any requested video codec"
            )
        }

        if dynamicRange == .hdr, !host.capabilities.supportsHDR {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Host does not advertise HDR-capable video modes"
            )
        }

        if preferredDecodeMode == .hardwareOnly, !host.capabilities.supportsHardwareDecode {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Host is not compatible with hardware-only decode mode"
            )
        }

        if preferredDecodeMode == .softwareFallback,
           !host.capabilities.supportsHardwareDecode,
           !host.capabilities.supportsSoftwareDecodeFallback
        {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Host is not compatible with the requested decode mode"
            )
        }

        if (resolution.width > 4096 || resolution.height > 4096),
           !supportedRequestedCodecs.contains(where: { $0 == .hevc || $0 == .av1 })
        {
            throw MoonlightError(
                .capabilityMismatch,
                message: "Streaming above 4K requires a host-supported HEVC or AV1 mode"
            )
        }
    }
}

public struct RemoteInputSecrets: Equatable, Sendable {
    public var key: Data
    public var keyID: UInt32

    public init(key: Data, keyID: UInt32) {
        self.key = key
        self.keyID = keyID
    }
}

public struct SessionEncryptionFeatures: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let controlV2 = SessionEncryptionFeatures(rawValue: 0x01)
    public static let video = SessionEncryptionFeatures(rawValue: 0x02)
    public static let audio = SessionEncryptionFeatures(rawValue: 0x04)
}

public struct NegotiatedSession: Equatable, Sendable {
    public var hostID: HostID
    public var appID: RemoteApp.ID
    public var rtspSessionURL: String
    public var videoFormat: VideoFormat?
    public var audioFormat: AudioFormat?
    public var remoteInputSecrets: RemoteInputSecrets?
    public var encryptionFeatures: SessionEncryptionFeatures
    public var isInputOnly: Bool
    public var channels: [EstablishedChannel]

    public init(
        hostID: HostID,
        appID: RemoteApp.ID,
        rtspSessionURL: String,
        videoFormat: VideoFormat? = nil,
        audioFormat: AudioFormat? = nil,
        remoteInputSecrets: RemoteInputSecrets? = nil,
        encryptionFeatures: SessionEncryptionFeatures = [],
        isInputOnly: Bool = false,
        channels: [EstablishedChannel] = []
    ) {
        self.hostID = hostID
        self.appID = appID
        self.rtspSessionURL = rtspSessionURL
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.remoteInputSecrets = remoteInputSecrets
        self.encryptionFeatures = encryptionFeatures
        self.isInputOnly = isInputOnly
        self.channels = channels
    }
}

public enum ChannelKind: String, Sendable, Equatable, CaseIterable {
    case control
    case input
    case video
    case audio
}

public struct ChannelDescriptor: Sendable, Equatable {
    public var kind: ChannelKind
    public var port: UInt16
    public var metadata: [String: String]

    public init(kind: ChannelKind, port: UInt16, metadata: [String: String] = [:]) {
        self.kind = kind
        self.port = port
        self.metadata = metadata
    }
}

public struct EstablishedChannel: Sendable, Equatable {
    public var descriptor: ChannelDescriptor
    public var isConnected: Bool

    public init(descriptor: ChannelDescriptor, isConnected: Bool = true) {
        self.descriptor = descriptor
        self.isConnected = isConnected
    }
}

public struct ClientIdentity: Equatable, Sendable {
    public var identifier: UUID
    public var displayName: String

    public init(identifier: UUID = UUID(), displayName: String = "swift-moonlight") {
        self.identifier = identifier
        self.displayName = displayName
    }
}

public struct ControlTransportMetricsSnapshot: Equatable, Sendable, Codable {
    public var isConnected: Bool
    public var roundTripTimeMs: Int?
    public var roundTripTimeVarianceMs: Int?
    public var packetLossRatio: Double?
    public var packetLossVarianceRatio: Double?

    public init(
        isConnected: Bool = false,
        roundTripTimeMs: Int? = nil,
        roundTripTimeVarianceMs: Int? = nil,
        packetLossRatio: Double? = nil,
        packetLossVarianceRatio: Double? = nil
    ) {
        self.isConnected = isConnected
        self.roundTripTimeMs = roundTripTimeMs
        self.roundTripTimeVarianceMs = roundTripTimeVarianceMs
        self.packetLossRatio = packetLossRatio
        self.packetLossVarianceRatio = packetLossVarianceRatio
    }
}

public struct SessionMetricsSnapshot: Equatable, Sendable, Codable {
    public var sessionOpenDurationMs: Int?
    public var controlRoundTripTimeMs: Int?
    public var controlRoundTripTimeVarianceMs: Int?
    public var controlPacketLossRatio: Double?
    public var controlPacketLossVarianceRatio: Double?
    public var inputEventsSent: Int
    public var inputPacketsSent: Int
    public var rendererAttachments: Int
    public var audioSinkAttachments: Int
    public var establishedChannelCount: Int
    public var controlMessagesObserved: Int
    public var videoPacketsObserved: Int
    public var audioPacketsObserved: Int
    public var audioConcealmentPackets: Int
    public var missingVideoPackets: Int
    public var missingAudioPackets: Int
    public var reorderedVideoPackets: Int
    public var reorderedAudioPackets: Int
    public var videoDiscontinuityEvents: Int
    public var videoFrameFECStatusReports: Int
    public var recoverableVideoDecodeFailures: Int
    public var reconnectAttempts: Int
    public var decodedVideoFrames: Int
    public var renderedVideoFrames: Int
    public var decodedAudioBuffers: Int
    public var playedAudioBuffers: Int
    public var averageVideoDecodeLatencyMs: Double?
    public var maxVideoDecodeLatencyMs: Double?
    public var averageHostProcessingLatencyMs: Double?
    public var maxHostProcessingLatencyMs: Double?
    public var averageAudioDecodeLatencyMs: Double?
    public var maxAudioDecodeLatencyMs: Double?
    public var averageInputQueueLatencyMs: Double?
    public var maxInputQueueLatencyMs: Double?
    public var averageInputTransportLatencyMs: Double?
    public var maxInputTransportLatencyMs: Double?
    public var audioUnderrunEvents: Int
    public var unexpectedDisconnect: Bool

    public init(
        sessionOpenDurationMs: Int? = nil,
        controlRoundTripTimeMs: Int? = nil,
        controlRoundTripTimeVarianceMs: Int? = nil,
        controlPacketLossRatio: Double? = nil,
        controlPacketLossVarianceRatio: Double? = nil,
        inputEventsSent: Int = 0,
        inputPacketsSent: Int = 0,
        rendererAttachments: Int = 0,
        audioSinkAttachments: Int = 0,
        establishedChannelCount: Int = 0,
        controlMessagesObserved: Int = 0,
        videoPacketsObserved: Int = 0,
        audioPacketsObserved: Int = 0,
        audioConcealmentPackets: Int = 0,
        missingVideoPackets: Int = 0,
        missingAudioPackets: Int = 0,
        reorderedVideoPackets: Int = 0,
        reorderedAudioPackets: Int = 0,
        videoDiscontinuityEvents: Int = 0,
        videoFrameFECStatusReports: Int = 0,
        recoverableVideoDecodeFailures: Int = 0,
        reconnectAttempts: Int = 0,
        decodedVideoFrames: Int = 0,
        renderedVideoFrames: Int = 0,
        decodedAudioBuffers: Int = 0,
        playedAudioBuffers: Int = 0,
        averageVideoDecodeLatencyMs: Double? = nil,
        maxVideoDecodeLatencyMs: Double? = nil,
        averageHostProcessingLatencyMs: Double? = nil,
        maxHostProcessingLatencyMs: Double? = nil,
        averageAudioDecodeLatencyMs: Double? = nil,
        maxAudioDecodeLatencyMs: Double? = nil,
        averageInputQueueLatencyMs: Double? = nil,
        maxInputQueueLatencyMs: Double? = nil,
        averageInputTransportLatencyMs: Double? = nil,
        maxInputTransportLatencyMs: Double? = nil,
        audioUnderrunEvents: Int = 0,
        unexpectedDisconnect: Bool = false
    ) {
        self.sessionOpenDurationMs = sessionOpenDurationMs
        self.controlRoundTripTimeMs = controlRoundTripTimeMs
        self.controlRoundTripTimeVarianceMs = controlRoundTripTimeVarianceMs
        self.controlPacketLossRatio = controlPacketLossRatio
        self.controlPacketLossVarianceRatio = controlPacketLossVarianceRatio
        self.inputEventsSent = inputEventsSent
        self.inputPacketsSent = inputPacketsSent
        self.rendererAttachments = rendererAttachments
        self.audioSinkAttachments = audioSinkAttachments
        self.establishedChannelCount = establishedChannelCount
        self.controlMessagesObserved = controlMessagesObserved
        self.videoPacketsObserved = videoPacketsObserved
        self.audioPacketsObserved = audioPacketsObserved
        self.audioConcealmentPackets = audioConcealmentPackets
        self.missingVideoPackets = missingVideoPackets
        self.missingAudioPackets = missingAudioPackets
        self.reorderedVideoPackets = reorderedVideoPackets
        self.reorderedAudioPackets = reorderedAudioPackets
        self.videoDiscontinuityEvents = videoDiscontinuityEvents
        self.videoFrameFECStatusReports = videoFrameFECStatusReports
        self.recoverableVideoDecodeFailures = recoverableVideoDecodeFailures
        self.reconnectAttempts = reconnectAttempts
        self.decodedVideoFrames = decodedVideoFrames
        self.renderedVideoFrames = renderedVideoFrames
        self.decodedAudioBuffers = decodedAudioBuffers
        self.playedAudioBuffers = playedAudioBuffers
        self.averageVideoDecodeLatencyMs = averageVideoDecodeLatencyMs
        self.maxVideoDecodeLatencyMs = maxVideoDecodeLatencyMs
        self.averageHostProcessingLatencyMs = averageHostProcessingLatencyMs
        self.maxHostProcessingLatencyMs = maxHostProcessingLatencyMs
        self.averageAudioDecodeLatencyMs = averageAudioDecodeLatencyMs
        self.maxAudioDecodeLatencyMs = maxAudioDecodeLatencyMs
        self.averageInputQueueLatencyMs = averageInputQueueLatencyMs
        self.maxInputQueueLatencyMs = maxInputQueueLatencyMs
        self.averageInputTransportLatencyMs = averageInputTransportLatencyMs
        self.maxInputTransportLatencyMs = maxInputTransportLatencyMs
        self.audioUnderrunEvents = audioUnderrunEvents
        self.unexpectedDisconnect = unexpectedDisconnect
    }
}

public struct MoonlightWarning: Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum ControllerFeedbackEffect: Sendable, Equatable {
    case capabilities(supportsRumble: Bool)
    case rumble(lowFrequencyMotor: UInt16, highFrequencyMotor: UInt16)
    case triggerRumble(leftTriggerMotor: UInt16, rightTriggerMotor: UInt16)
    case motionReport(motionType: UInt8, reportRateHz: UInt16)
    case led(red: UInt8, green: UInt8, blue: UInt8)
    case adaptiveTriggers(
        eventFlags: UInt8,
        leftTriggerType: UInt8,
        rightTriggerType: UInt8,
        leftPayload: [UInt8],
        rightPayload: [UInt8]
    )

    public var requestsRumble: Bool {
        switch self {
        case .capabilities(let supportsRumble):
            supportsRumble
        case .rumble, .triggerRumble:
            true
        case .motionReport, .led, .adaptiveTriggers:
            false
        }
    }
}

public struct ControllerFeedback: Sendable, Equatable {
    public var controllerID: Int
    public var supportsRumble: Bool
    public var effect: ControllerFeedbackEffect

    public init(controllerID: Int, supportsRumble: Bool) {
        self.controllerID = controllerID
        self.supportsRumble = supportsRumble
        self.effect = .capabilities(supportsRumble: supportsRumble)
    }

    public init(controllerID: Int, effect: ControllerFeedbackEffect) {
        self.controllerID = controllerID
        self.supportsRumble = effect.requestsRumble
        self.effect = effect
    }
}

public protocol ControllerFeedbackSink: Sendable {
    func apply(_ feedback: ControllerFeedback) async throws
}
