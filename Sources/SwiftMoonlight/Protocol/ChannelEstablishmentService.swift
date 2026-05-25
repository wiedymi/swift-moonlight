import Foundation

public struct ChannelPlan: Sendable, Equatable {
    public var descriptors: [ChannelDescriptor]

    public init(descriptors: [ChannelDescriptor]) {
        self.descriptors = descriptors
    }
}

public struct ChannelPlanBuilder: Sendable {
    public init() {}

    public func buildPlan(from negotiation: RTSPNegotiationResult, isInputOnly: Bool) -> ChannelPlan {
        var descriptors: [ChannelDescriptor] = []

        if let controlPort = negotiation.control?.serverPort {
            var controlMetadata: [String: String] = [:]
            var inputMetadata: [String: String] = [:]
            if let connectData = negotiation.control?.controlConnectData {
                let value = String(connectData)
                controlMetadata["connectData"] = value
                inputMetadata["connectData"] = value
            }
            descriptors.append(.init(kind: .control, port: controlPort, metadata: controlMetadata))
            descriptors.append(.init(kind: .input, port: controlPort, metadata: inputMetadata))
        }

        if !isInputOnly {
            if let videoPort = negotiation.video.serverPort {
                var videoMetadata: [String: String] = [:]
                if let payload = negotiation.video.pingPayload {
                    videoMetadata["pingPayload"] = payload
                }
                descriptors.append(.init(kind: .video, port: videoPort, metadata: videoMetadata))
            }
            if let audioPort = negotiation.audio.serverPort {
                var audioMetadata: [String: String] = [:]
                if let payload = negotiation.audio.pingPayload {
                    audioMetadata["pingPayload"] = payload
                }
                descriptors.append(.init(kind: .audio, port: audioPort, metadata: audioMetadata))
            }
        }

        return ChannelPlan(descriptors: descriptors)
    }
}

public struct ChannelEstablishmentService: Sendable {
    public let transport: any ChannelTransport
    public let planBuilder: ChannelPlanBuilder

    public init(
        transport: any ChannelTransport,
        planBuilder: ChannelPlanBuilder = ChannelPlanBuilder()
    ) {
        self.transport = transport
        self.planBuilder = planBuilder
    }

    public func establish(
        host: MoonlightHost,
        negotiation: RTSPNegotiationResult,
        isInputOnly: Bool
    ) async throws -> [EstablishedChannel] {
        let plan = planBuilder.buildPlan(from: negotiation, isInputOnly: isInputOnly)
        return try await establish(host: host, descriptors: plan.descriptors)
    }

    public func establish(
        host: MoonlightHost,
        descriptors: [ChannelDescriptor]
    ) async throws -> [EstablishedChannel] {
        var channels: [EstablishedChannel] = []
        channels.reserveCapacity(descriptors.count)

        for descriptor in descriptors {
            let established = try await transport.establishChannel(to: host, descriptor: descriptor)
            channels.append(established)
        }

        return channels
    }
}

public struct SessionBootstrap: SessionBootstrapService {
    public let launchService: any SessionService
    public let rtspService: RTSPNegotiationService
    public let channelService: ChannelEstablishmentService
    public let socketFactory: ChannelSocketFactory
    public let opusConfigurationParser: OpusConfigurationParser
    public let rtspAnnounceSDPBuilder: RTSPAnnounceSDPBuilder

    public init(
        launchService: any SessionService,
        rtspService: RTSPNegotiationService,
        channelService: ChannelEstablishmentService,
        socketFactory: ChannelSocketFactory = .init(),
        opusConfigurationParser: OpusConfigurationParser = .init(),
        rtspAnnounceSDPBuilder: RTSPAnnounceSDPBuilder = .init()
    ) {
        self.launchService = launchService
        self.rtspService = rtspService
        self.channelService = channelService
        self.socketFactory = socketFactory
        self.opusConfigurationParser = opusConfigurationParser
        self.rtspAnnounceSDPBuilder = rtspAnnounceSDPBuilder
    }

    public func openSession(
        host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        identity: ClientIdentity
    ) async throws -> BootstrappedSession {
        var negotiated = try await launchService.launchSession(
            for: host,
            appID: appID,
            configuration: configuration,
            identity: identity
        )
        let isInputOnly = negotiated.isInputOnly
        let remoteInputSecrets = negotiated.remoteInputSecrets
        let channelCapture = EstablishedChannelCapture()
        let socketCapture = PrimedSocketCapture()

        let rtsp = try await rtspService.negotiate(
            sessionURL: negotiated.rtspSessionURL,
            sdpBuilder: { describeInfo in
                let negotiatedEncryption = buildEnabledEncryptionFeatures(
                    describeInfo: describeInfo,
                    configuration: configuration,
                    secrets: remoteInputSecrets
                )
                return rtspAnnounceSDPBuilder.build(
                    for: configuration,
                    negotiatedEncryption: negotiatedEncryption
                )
            },
            remoteInputKey: remoteInputSecrets?.key,
            useUnifiedPlay: true,
            includeControlStream: !isInputOnly,
            afterAudioSetup: { audioInfo, _ in
                guard !isInputOnly,
                      let audioPort = audioInfo.serverPort
                else {
                    return
                }

                var metadata: [String: String] = [:]
                if let pingPayload = audioInfo.pingPayload {
                    metadata["pingPayload"] = pingPayload
                }
                let audioChannel = EstablishedChannel(
                    descriptor: .init(kind: .audio, port: audioPort, metadata: metadata),
                    isConnected: true
                )
                let audioSockets = try await socketFactory.makeAndPrimeSockets(
                    for: host,
                    channels: [audioChannel],
                    includeControlTransports: false
                )
                var establishedAudioChannel = audioChannel
                if let localPort = try await audioSockets.audioSource?.localPort() {
                    establishedAudioChannel.descriptor.metadata["localPort"] = String(localPort)
                }
                await channelCapture.append(establishedAudioChannel)
                await socketCapture.merge(audioSockets)
            },
            prePlay: { rtsp in
                let encryptionFeatures = buildEnabledEncryptionFeatures(
                    describeInfo: rtsp.describeInfo,
                    configuration: configuration,
                    secrets: remoteInputSecrets
                )
                let controlEncryption: ControlEncryptionContext?
                if encryptionFeatures.contains(.controlV2),
                   let key = remoteInputSecrets?.key
                {
                    controlEncryption = ControlEncryptionContext(key: key, version: .v2)
                } else {
                    controlEncryption = nil
                }
                let existingSockets = await socketCapture.load()
                let plan = channelService.planBuilder.buildPlan(from: rtsp, isInputOnly: isInputOnly)
                let descriptors = existingSockets?.audioSource == nil
                    ? plan.descriptors
                    : plan.descriptors.filter { $0.kind != .audio }
                let establishedChannels = try await channelService.establish(
                    host: host,
                    descriptors: descriptors
                )
                var channels = establishedChannels
                if existingSockets?.audioSource != nil,
                   let earlyAudioChannel = await channelCapture.first(kind: .audio)
                {
                    channels.append(earlyAudioChannel)
                }
                await channelCapture.store(channels)
                let channelsNeedingSockets = existingSockets?.audioSource == nil
                    ? channels
                    : channels.filter { $0.descriptor.kind != .audio }
                // Create sockets before PLAY so we are ready to receive the initial
                // keyframe that Sunshine sends immediately after PLAY completes.
                // ICMP port-unreachable errors from early pings are handled by the
                // BoundUDPSocket receive loop.
                let primedSockets = try await socketFactory.makeAndPrimeSockets(
                    for: host,
                    channels: channelsNeedingSockets,
                    controlEncryption: controlEncryption,
                    includeControlTransports: false
                )
                await socketCapture.merge(primedSockets)
            }
        )
        negotiated.videoFormat = buildVideoFormat(
            existing: negotiated.videoFormat,
            sdp: rtsp.describeInfo.sdp,
            configuration: configuration
        )
        negotiated.encryptionFeatures = buildEnabledEncryptionFeatures(
            describeInfo: rtsp.describeInfo,
            configuration: configuration,
            secrets: negotiated.remoteInputSecrets
        )
        if let sdp = rtsp.describeInfo.sdp {
            negotiated.audioFormat = try buildAudioFormat(
                existing: negotiated.audioFormat,
                sdp: sdp,
                audioMode: configuration.audioMode
            )
        }
        negotiated.channels = await channelCapture.load()
        return BootstrappedSession(
            negotiatedSession: negotiated,
            primedSockets: await socketCapture.take()
        )
    }

    private func buildVideoFormat(
        existing: VideoFormat?,
        sdp: String?,
        configuration: StreamConfiguration
    ) -> VideoFormat {
        if let existing {
            return existing
        }

        _ = sdp
        let codec = configuration.videoCodecPreference.first ?? .h264

        return VideoFormat(
            codec: codec,
            dimensions: configuration.resolution,
            dynamicRange: configuration.dynamicRange
        )
    }

    private func buildEnabledEncryptionFeatures(
        describeInfo: RTSPDescribeInfo,
        configuration: StreamConfiguration,
        secrets: RemoteInputSecrets?
    ) -> SessionEncryptionFeatures {
        guard secrets != nil else {
            return []
        }

        var enabled: SessionEncryptionFeatures = []
        let supported = describeInfo.encryptionSupported
        let requested = describeInfo.encryptionRequested

        if configuration.enableControlEncryption && supported.contains(.controlV2) {
            enabled.insert(.controlV2)
        }
        if requested.contains(.video) || (configuration.enableVideoEncryption && supported.contains(.video)) {
            enabled.insert(.video)
        }
        if requested.contains(.audio) || (configuration.enableAudioEncryption && supported.contains(.audio)) {
            enabled.insert(.audio)
        }

        return enabled
    }

    private func buildAudioFormat(
        existing: AudioFormat?,
        sdp: String,
        audioMode: AudioMode
    ) throws -> AudioFormat {
        let config = try opusConfigurationParser.parse(sdp: sdp, audioMode: audioMode)
        return AudioFormat(
            sampleRate: existing?.sampleRate ?? config.sampleRate,
            channelCount: existing?.channelCount ?? config.channelCount,
            opusConfiguration: config
        )
    }
}

private actor EstablishedChannelCapture {
    private var channels: [EstablishedChannel] = []

    func store(_ channels: [EstablishedChannel]) {
        self.channels = channels
    }

    func append(_ channel: EstablishedChannel) {
        channels.append(channel)
    }

    func first(kind: ChannelKind) -> EstablishedChannel? {
        channels.first { $0.descriptor.kind == kind }
    }

    func load() -> [EstablishedChannel] {
        channels
    }
}

private actor PrimedSocketCapture {
    private var sockets: ChannelSocketSet?

    func store(_ sockets: ChannelSocketSet) {
        self.sockets = sockets
    }

    func load() -> ChannelSocketSet? {
        sockets
    }

    func merge(_ newSockets: ChannelSocketSet) {
        var merged = sockets ?? ChannelSocketSet()
        if merged.controlTransport == nil {
            merged.controlTransport = newSockets.controlTransport
        }
        if merged.inputTransport == nil {
            merged.inputTransport = newSockets.inputTransport
        }
        if merged.videoSource == nil {
            merged.videoSource = newSockets.videoSource
        }
        if merged.audioSource == nil {
            merged.audioSource = newSockets.audioSource
        }
        sockets = merged
    }

    func take() -> ChannelSocketSet? {
        defer { sockets = nil }
        return sockets
    }
}
