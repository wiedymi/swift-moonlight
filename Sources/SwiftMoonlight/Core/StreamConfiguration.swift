import CoreGraphics
import Foundation

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
