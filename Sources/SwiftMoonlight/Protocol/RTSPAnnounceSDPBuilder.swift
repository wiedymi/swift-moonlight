import Foundation

public struct RTSPAnnounceSDPBuilder: Sendable {
    private static let moonlightFeatureFlags = 0x01 | 0x02
    private static let nvBaseFeatureFlags = 135
    private static let nvRiEncryptionFlag = 0x200
    private static let nvAudioEncryptionFlag = 0x20
    private static let encryptedVideoHeaderSize = 32

    public init() {}

    public func build(for configuration: StreamConfiguration) -> Data {
        build(for: configuration, negotiatedEncryption: encryptionFlags(for: configuration))
    }

    public func build(for configuration: StreamConfiguration, negotiatedEncryption: SessionEncryptionFeatures) -> Data {
        let width = Int(configuration.resolution.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(configuration.resolution.height.rounded(.toNearestOrAwayFromZero))
        let encryptionEnabled = negotiatedEncryption
        let selectedCodec = preferredVideoCodec(for: configuration)
        let lines = [
            "v=0",
            "s=stream",
            "a=x-ml-general.featureFlags:\(Self.moonlightFeatureFlags)",
            "a=x-nv-general.featureFlags:\(nvGeneralFeatureFlags(audioEncrypted: encryptionEnabled.contains(.audio)))",
            "a=x-nv-general.useReliableUdp:13",
            "a=x-nv-vqos[0].fec.minRequiredFecPackets:2",
            "a=x-nv-vqos[0].bllFec.enable:0",
            "a=x-nv-vqos[0].drc.enable:0",
            "a=x-nv-general.enableRecoveryMode:0",
            "a=x-ss-general.encryptionEnabled:\(encryptionEnabled.rawValue)",
            "a=x-ss-video[0].chromaSamplingType:0",
            "a=x-ss-video[0].intraRefresh:0",
            "a=x-nv-audio.surround.numChannels:\(configuration.audioMode.channelCount)",
            "a=x-nv-audio.surround.channelMask:\(channelMask(for: configuration.audioMode))",
            "a=x-nv-audio.surround.enable:\(configuration.audioMode.channelCount > 2 ? 1 : 0)",
            "a=x-nv-audio.surround.AudioQuality:0",
            "a=x-nv-aqos.packetDuration:5",
            "a=x-nv-aqos.qosTrafficType:4",
            "a=x-nv-video[0].packetSize:\(packetSize(for: configuration, videoEncrypted: encryptionEnabled.contains(.video)))",
            "a=x-nv-video[0].clientViewportHt:\(height)",
            "a=x-nv-video[0].clientViewportWd:\(width)",
            "a=x-nv-video[0].maxFPS:\(configuration.frameRate)",
            "a=x-nv-video[0].rateControlMode:4",
            "a=x-nv-video[0].timeoutLengthMs:7000",
            "a=x-nv-video[0].framesWithInvalidRefThreshold:0",
            "a=x-nv-vqos[0].fec.enable:1",
            "a=x-nv-vqos[0].videoQualityScoreUpdateTime:5000",
            "a=x-nv-vqos[0].qosTrafficType:5",
            "a=x-ml-video.configuredBitrateKbps:\(configuration.bitrateKbps)",
            "a=x-nv-video[0].initialBitrateKbps:\(configuration.bitrateKbps)",
            "a=x-nv-video[0].initialPeakBitrateKbps:\(configuration.bitrateKbps)",
            "a=x-nv-vqos[0].bw.minimumBitrateKbps:\(configuration.bitrateKbps)",
            "a=x-nv-vqos[0].bw.maximumBitrateKbps:\(configuration.bitrateKbps)",
            "a=x-nv-video[0].videoEncoderSlicesPerFrame:1",
            "a=x-nv-video[0].maxNumReferenceFrames:1",
            "a=x-nv-video[0].clientRefreshRateX100:\(configuration.frameRate * 100)",
            "a=x-nv-video[0].dynamicRangeMode:\(configuration.dynamicRange == .hdr ? 1 : 0)",
            "a=x-nv-video[0].encoderCscMode:0",
            "a=x-nv-clientSupportHevc:\(selectedCodec == .hevc ? 1 : 0)",
            "a=x-nv-vqos[0].bitStreamFormat:\(bitStreamFormat(for: selectedCodec))",
            "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func channelMask(for audioMode: AudioMode) -> Int {
        switch audioMode {
        case .stereo:
            return 0x3
        case .surround51:
            return 0x3F
        case .surround71:
            return 0x63F
        }
    }

    private func packetSize(for configuration: StreamConfiguration, videoEncrypted: Bool = false) -> Int {
        let maxDimension = max(configuration.resolution.width, configuration.resolution.height)
        let baseSize = maxDimension >= 1080 ? 1392 : 1024
        guard videoEncrypted else {
            return baseSize
        }
        return max(0, baseSize - Self.encryptedVideoHeaderSize)
    }

    private func encryptionFlags(for configuration: StreamConfiguration) -> SessionEncryptionFeatures {
        var flags: SessionEncryptionFeatures = []
        if configuration.enableControlEncryption {
            flags.insert(.controlV2)
        }
        if configuration.enableVideoEncryption {
            flags.insert(.video)
        }
        if configuration.enableAudioEncryption {
            flags.insert(.audio)
        }
        return flags
    }

    private func nvGeneralFeatureFlags(audioEncrypted: Bool) -> Int {
        var flags = Self.nvBaseFeatureFlags | Self.nvRiEncryptionFlag
        if audioEncrypted {
            flags |= Self.nvAudioEncryptionFlag
        }
        return flags
    }

    private func preferredVideoCodec(for configuration: StreamConfiguration) -> VideoCodec {
        configuration.videoCodecPreference.first ?? .h264
    }

    private func bitStreamFormat(for codec: VideoCodec) -> Int {
        switch codec {
        case .h264:
            return 0
        case .hevc:
            return 1
        case .av1:
            return 2
        }
    }
}
