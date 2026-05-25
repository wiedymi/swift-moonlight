import Foundation

public struct PreparedSessionRuntime: Sendable {
    public let runtime: SessionRuntime
    public let sockets: ChannelSocketSet

    public init(runtime: SessionRuntime, sockets: ChannelSocketSet) {
        self.runtime = runtime
        self.sockets = sockets
    }

    public func stop() async {
        await runtime.stop()
        await sockets.close()
    }
}

public struct SessionRuntimeFactory: Sendable {
    public let socketFactory: ChannelSocketFactory
    public let logger: any MoonlightLogger

    public init(
        socketFactory: ChannelSocketFactory = .init(),
        logger: any MoonlightLogger
    ) {
        self.socketFactory = socketFactory
        self.logger = logger
    }

    public func makeRuntime(
        host: MoonlightHost,
        session: MoonlightSession,
        configuration: StreamRuntimeConfiguration = .init()
    ) async throws -> PreparedSessionRuntime {
        guard let negotiatedSession = await session.negotiatedSession else {
            throw MoonlightError(.unsupportedOperation, message: "Cannot prepare runtime for a session without negotiated channel metadata")
        }

        var runtimeConfiguration = configuration

        if runtimeConfiguration.controlEncryption == nil,
           negotiatedSession.encryptionFeatures.contains(.controlV2),
           let remoteInputSecrets = negotiatedSession.remoteInputSecrets
        {
            runtimeConfiguration.controlEncryption = ControlEncryptionContext(
                key: remoteInputSecrets.key,
                version: .v2
            )
        }

        var sockets = if let primed = await session.takePrimedSockets() {
            primed
        } else {
            try await socketFactory.makeAndPrimeSockets(
                for: host,
                controlEncryption: runtimeConfiguration.controlEncryption,
                negotiatedSession: negotiatedSession
            )
        }

        if sockets.controlTransport == nil || sockets.inputTransport == nil {
            let controlChannels = negotiatedSession.channels.filter {
                $0.descriptor.kind == .control || $0.descriptor.kind == .input
            }
            let controlSockets = try socketFactory.makeSockets(
                for: host,
                channels: controlChannels,
                controlEncryption: runtimeConfiguration.controlEncryption
            )
            if sockets.controlTransport == nil {
                sockets.controlTransport = controlSockets.controlTransport
            }
            if sockets.inputTransport == nil {
                sockets.inputTransport = controlSockets.inputTransport
            }
        }

        if let inputTransport = sockets.inputTransport {
            let inputContext = InputEncodingContext(
                host: host,
                negotiatedSession: negotiatedSession
            )
            let sender = InputSender(
                context: inputContext,
                transport: inputTransport,
                configuration: runtimeConfiguration.inputSenderConfiguration
            )
            await session.attachInputSender(sender)
        }

        if let videoFormat = negotiatedSession.videoFormat {
            try await session.configureVideo(format: videoFormat)
        }
        if let audioFormat = negotiatedSession.audioFormat {
            try await session.configureAudio(format: audioFormat)
        }

        let controlService = sockets.controlTransport.map {
            ControlChannelService(transport: $0, logger: logger)
        }
        let pipeline = await session.mediaPipelineHandle()
        let videoService = negotiatedSession.videoFormat.flatMap { videoFormat in
            sockets.videoSource.map {
                VideoIngestService(
                    source: $0,
                    decryptor: negotiatedSession.encryptionFeatures.contains(.video) ? VideoPacketDecryptor() : nil,
                    encryptionContext: negotiatedSession.remoteInputSecrets.map {
                        VideoEncryptionContext(key: $0.key)
                    },
                    depacketizer: SimpleVideoDepacketizer(
                        configuration: .init(codec: videoFormat.codec, dimensions: videoFormat.dimensions)
                    ),
                    pipeline: pipeline,
                    packetTraceLimit: runtimeConfiguration.videoPacketTraceLimit,
                    pipelineSubmissionMode: runtimeConfiguration.videoPipelineSubmissionMode
                )
            }
        }
        let audioService = negotiatedSession.audioFormat.flatMap { _ in
            sockets.audioSource.map {
                AudioIngestService(
                    source: $0,
                    decryptor: negotiatedSession.encryptionFeatures.contains(.audio) ? AudioPacketDecryptor() : nil,
                    encryptionContext: negotiatedSession.remoteInputSecrets.map {
                        AudioEncryptionContext(key: $0.key, avRiKeyID: $0.keyID)
                    },
                    pipeline: pipeline
                )
            }
        }

        let runtime = SessionRuntime(
            session: session,
            controlService: controlService,
            videoService: videoService,
            audioService: audioService,
            configuration: runtimeConfiguration
        )

        return PreparedSessionRuntime(runtime: runtime, sockets: sockets)
    }
}
