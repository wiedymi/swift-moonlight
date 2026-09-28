import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func sessionRuntimeEmitsHDRModeEvents() async throws {
    let session = MoonlightSession()
    let controlTransport = RecordingControlChannelTransport(receivedPackets: [
        try #require(Data(hexString:
            "0E0101" +
            "6400C8002C019001F4015802" +
            "BC022003" +
            "E8030A0014001E002800"
        ))
    ])
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let runtime = SessionRuntime(session: session, controlService: control)
    let events = await session.events

    await runtime.start()
    let updates = await collectHDRModeEvents(from: events, count: 1)
    await runtime.stop()

    #expect(updates == [
        .init(
            enabled: true,
            metadata: HDRMetadata(
                displayPrimaries: [
                    .init(x: 100, y: 200),
                    .init(x: 300, y: 400),
                    .init(x: 500, y: 600),
                ],
                whitePoint: .init(x: 700, y: 800),
                maxDisplayLuminance: 1000,
                minDisplayLuminance: 10,
                maxContentLightLevel: 20,
                maxFrameAverageLightLevel: 30,
                maxFullFrameLuminance: 40
            )
        )
    ])
}

@Test
func sessionRuntimePumpsControlVideoAndAudio() async throws {
    let session = MoonlightSession()
    try await session.attachVideoDecoder(RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 33, dimensions: CGSize(width: 640, height: 360), bytes: Data([0x01]))
    ]]))
    let renderer = RecordingRenderer()
    try await session.attachRenderer(renderer)
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x10, 0x20]))
    ]))
    let sink = RecordingAudioSink()
    try await session.attachAudioSink(sink)
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    try await session.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let controlTransport = RecordingControlChannelTransport(receivedPackets: [
        try #require(Data(hexString: "0B0100000000010022114433"))
    ])
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())

    let videoSource = FixtureMediaPacketSource(packets: [
        makeRuntimeVideoPacket(
            sequenceNumber: 1,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 1,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0x01, 0x99, 0x00, 0, 0, 0, 0, 0, 0x99])
        )
    ])

    let video = VideoIngestService(
        source: videoSource,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360))),
        pipeline: await session.mediaPipelineHandle()
    )
    let audioSource = FixtureMediaPacketSource(packets: [
        makeRuntimeAudioPacket(sequenceNumber: 1, timestamp: 960, payload: Data([0xA1, 0xB2]))
    ])
    let audio = AudioIngestService(source: audioSource, pipeline: await session.mediaPipelineHandle())

    let runtime = SessionRuntime(session: session, controlService: control, videoService: video, audioService: audio)
    await runtime.start()

    let events = await session.events
    var iterator = events.makeAsyncIterator()
    var feedbackSeen = false
    var timeoutCount = 0
    while !feedbackSeen && timeoutCount < 10 {
        if let event = await iterator.next() {
            if case .controllerFeedback(let feedback) = event {
                #expect(feedback.controllerID == 1)
                #expect(feedback.supportsRumble)
                #expect(feedback.effect == .rumble(
                    lowFrequencyMotor: 0x1122,
                    highFrequencyMotor: 0x3344
                ))
                feedbackSeen = true
            }
        } else {
            timeoutCount += 1
        }
        try await Task.sleep(for: .milliseconds(5))
    }

    let rendered = await renderer.recordedFrames()
    let played = await sink.recordedBuffers()

    #expect(feedbackSeen)
    #expect(rendered.count >= 1)
    #expect(played.count >= 1)
    await runtime.stop()
}

private struct SlowRenderer: FrameRenderer {
    func prepare(format: VideoFormat) async throws {}
    func render(_ frame: DecodedVideoFrame) async {
        try? await Task.sleep(for: .milliseconds(15))
    }
    func teardown() async {}
}

@Test
func videoMetricsShowQueueWaitAndSlowRenderSubmission() async throws {
    let pipeline = MediaPipeline()
    let decodedFrame = DecodedVideoFrame(
        timestamp: 1,
        dimensions: CGSize(width: 640, height: 360),
        bytes: Data([0x01])
    )
    try await pipeline.attachVideoDecoder(RecordingVideoDecoder(decodeOutputs: Array(repeating: [decodedFrame], count: 4)))
    try await pipeline.attachRenderer(SlowRenderer())
    try await pipeline.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))

    let packets = (1...4).map { index in
        makeRuntimeVideoPacket(
            sequenceNumber: UInt16(index),
            timestamp: UInt32(index * 3_000),
            streamPacketIndex: 1,
            frameIndex: UInt32(index),
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data(repeating: 0, count: 8) + Data([0x99])
        )
    }
    let service = VideoIngestService(
        source: FixtureMediaPacketSource(packets: packets),
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360))),
        pipeline: pipeline,
        pipelineSubmissionMode: .asynchronous(maxInFlightFrames: 4)
    )

    while try await service.receiveNextFrame() != nil {}

    let stats = await pipeline.snapshot()
    #expect(stats.decodedVideoFrames == 4)
    #expect(stats.renderedVideoFrames == 4)
    #expect((stats.maxVideoQueueLatencyMs ?? 0) >= 10)
    #expect((stats.averageVideoRenderSubmissionLatencyMs ?? 0) >= 10)
}

@Test
func audioMetricsPublishLessOftenThanPacketsAndKeepFinalCounts() async throws {
    let session = MoonlightSession()
    let buffer = PCMBuffer(
        sampleRate: 48_000,
        channelCount: 2,
        frameCount: 1,
        bytesPerFrame: 4,
        data: Data(repeating: 0, count: 4)
    )
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: Array(repeating: buffer, count: 32)))
    try await session.attachAudioSink(NullAudioSink())
    try await session.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let packets = (1...32).map { index in
        makeRuntimeAudioPacket(
            sequenceNumber: UInt16(index),
            timestamp: UInt32(index * 960),
            payload: Data([0xA1])
        )
    }
    let audioService = AudioIngestService(
        source: FixtureMediaPacketSource(packets: packets),
        pipeline: await session.mediaPipelineHandle()
    )
    let runtime = SessionRuntime(session: session, audioService: audioService)
    let metrics = await session.metrics
    let collected = Task { () -> [SessionMetricsSnapshot] in
        var snapshots: [SessionMetricsSnapshot] = []
        for await snapshot in metrics {
            snapshots.append(snapshot)
        }
        return snapshots
    }

    await runtime.start()
    let snapshot = await waitForRuntimeSnapshot(runtime) { $0.audioPacketsObserved == 32 }
    #expect(snapshot.audioPacketsObserved == 32)
    for _ in 0..<200 {
        let current = await session.currentMetricsSnapshot()
        if current.audioPacketsObserved == 32 && current.decodedAudioBuffers == 32 {
            break
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    await runtime.stop()

    let snapshots = await collected.value
    let publishedAudioSnapshots = snapshots.filter { $0.audioPacketsObserved > 0 }
    #expect(publishedAudioSnapshots.count < 32)
    #expect(publishedAudioSnapshots.last?.audioPacketsObserved == 32)
    #expect(publishedAudioSnapshots.last?.decodedAudioBuffers == 32)
}

@Test
func sessionRuntimeRoutesControllerFeedbackEffects() async throws {
    let session = MoonlightSession()
    let controlTransport = RecordingControlChannelTransport(receivedPackets: [
        try #require(Data(hexString: "0B0100000000010022114433")),
        try #require(Data(hexString: "0055030010002000")),
        try #require(Data(hexString: "01550200280002")),
        try #require(Data(hexString: "02550400102030")),
        Data([
            0x03, 0x55,
            0x01, 0x00,
            0x0C,
            0x01,
            0x02,
            0x01, 0x02, 0x03, 0x04, 0x05,
            0x06, 0x07, 0x08, 0x09, 0x0A,
            0x11, 0x12, 0x13, 0x14, 0x15,
            0x16, 0x17, 0x18, 0x19, 0x1A,
        ]),
    ])
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let runtime = SessionRuntime(session: session, controlService: control)
    let events = await session.events

    await runtime.start()
    let feedback = await collectControllerFeedbackEvents(from: events, count: 5)
    await runtime.stop()

    #expect(feedback == [
        .init(controllerID: 1, effect: .rumble(
            lowFrequencyMotor: 0x1122,
            highFrequencyMotor: 0x3344
        )),
        .init(controllerID: 3, effect: .triggerRumble(
            leftTriggerMotor: 16,
            rightTriggerMotor: 32
        )),
        .init(controllerID: 2, effect: .motionReport(
            motionType: 2,
            reportRateHz: 40
        )),
        .init(controllerID: 4, effect: .led(
            red: 0x10,
            green: 0x20,
            blue: 0x30
        )),
        .init(controllerID: 1, effect: .adaptiveTriggers(
            eventFlags: 0x0C,
            leftTriggerType: 0x01,
            rightTriggerType: 0x02,
            leftPayload: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            rightPayload: [0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A]
        )),
    ])
}

@Test
func sessionAppliesAttachedControllerFeedbackSink() async throws {
    let session = MoonlightSession()
    let sink = RecordingControllerFeedbackSink()
    await session.attachControllerFeedbackSink(sink)
    let feedback = ControllerFeedback(
        controllerID: 7,
        effect: .led(red: 0xAA, green: 0xBB, blue: 0xCC)
    )

    await session.receive(controllerFeedback: feedback)

    #expect(await sink.recordedFeedback() == [feedback])
}

@Test
func sessionWarnsWhenControllerFeedbackSinkFails() async throws {
    let session = MoonlightSession()
    await session.attachControllerFeedbackSink(FailingControllerFeedbackSink())
    let events = await session.events

    await session.receive(controllerFeedback: .init(
        controllerID: 3,
        effect: .rumble(lowFrequencyMotor: 1, highFrequencyMotor: 2)
    ))

    let sawWarning = await containsSessionWarning(
        in: events,
        timeout: .seconds(1)
    ) { warning in
        warning.message.contains("Controller feedback sink failed")
    }
    #expect(sawWarning)
}

@Test
func sessionRuntimeStopsOnTerminationMessage() async throws {
    let session = MoonlightSession()
    let controlTransport = RecordingControlChannelTransport(receivedPackets: [
        try #require(Data(hexString: "09010001"))
    ])
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let runtime = SessionRuntime(session: session, controlService: control)

    await runtime.start()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await session.currentState == .stopped)
}

@Test
func sessionRuntimeRequestsInitialIDRFrameAfterControlTrafficArrives() async throws {
    let session = MoonlightSession()
    let controlTransport = RecordingControlChannelTransport(receivedPackets: [
        try #require(Data(hexString: "0B0100000000010022114433"))
    ])
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let videoSource = FixtureMediaPacketSource()
    let video = VideoIngestService(
        source: videoSource,
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360))),
        pipeline: await session.mediaPipelineHandle()
    )

    let runtime = SessionRuntime(session: session, controlService: control, videoService: video)
    await runtime.start()
    var sent: [(packet: Data, channelID: UInt8, reliable: Bool)] = []
    var attempts = 0
    while sent.isEmpty && attempts < 20 {
        try await Task.sleep(for: .milliseconds(5))
        sent = await controlTransport.recordedSentPackets()
        attempts += 1
    }
    await runtime.stop()

    #expect(sent.count == 1)
    let packet = try #require(sent.first)
    #expect(packet.channelID == ControlChannelID.urgent)
    #expect(packet.reliable)
}

@Test
func runtimeSnapshotIncludesAudioConcealmentCount() async throws {
    let session = MoonlightSession()
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x10, 0x20])),
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x30, 0x40]))
    ]))
    try await session.attachAudioSink(RecordingAudioSink())
    try await session.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let audioSource = FixtureMediaPacketSource(packets: [
        makeRuntimeAudioPacket(sequenceNumber: 1, timestamp: 960, payload: Data([0xA1])),
        makeRuntimeAudioPacket(sequenceNumber: 4, timestamp: 3_840, payload: Data([0xB2]))
    ])
    let audio = AudioIngestService(
        source: audioSource,
        depacketizer: SimpleAudioDepacketizer(reorderWindowSize: 2),
        pipeline: await session.mediaPipelineHandle()
    )

    let runtime = SessionRuntime(session: session, audioService: audio)
    await runtime.start()
    let snapshot = await waitForRuntimeSnapshot(runtime) { snapshot in
        snapshot.audioConcealmentPackets >= 1
    }
    await runtime.stop()

    #expect(snapshot.audioConcealmentPackets == 1)
}

@Test
func sessionMetricsReceiveRuntimeObservationCounts() async throws {
    let session = MoonlightSession(clock: AdvancingTestClock(dates: [
        Date(timeIntervalSince1970: 1.000),
        Date(timeIntervalSince1970: 1.008),
        Date(timeIntervalSince1970: 2.000),
        Date(timeIntervalSince1970: 2.006)
    ]))
    try await session.attachVideoDecoder(RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 33, dimensions: CGSize(width: 640, height: 360), bytes: Data([0x01]))
    ]]))
    try await session.attachRenderer(NullRenderer())
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x10, 0x20]))
    ]))
    try await session.attachAudioSink(NullAudioSink())
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    try await session.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let controlTransport = RecordingControlChannelTransport(receivedPackets: [
        try #require(Data(hexString: "0B0100000000010022114433"))
    ])
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let videoSource = FixtureMediaPacketSource(packets: [
        makeRuntimeVideoPacket(
            sequenceNumber: 1,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 1,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0x01, 0x99, 0x00, 0, 0, 0, 0, 0, 0x99])
        )
    ])
    let audioSource = FixtureMediaPacketSource(packets: [
        makeRuntimeAudioPacket(sequenceNumber: 1, timestamp: 960, payload: Data([0xA1, 0xB2]))
    ])

    let runtime = SessionRuntime(
        session: session,
        controlService: control,
        videoService: VideoIngestService(
            source: videoSource,
            depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360))),
            pipeline: await session.mediaPipelineHandle()
        ),
        audioService: AudioIngestService(
            source: audioSource,
            pipeline: await session.mediaPipelineHandle()
        )
    )

    let metricsStream = await session.metrics
    await runtime.start()
    let metrics = try #require(await latestMetricSnapshot(
        from: metricsStream,
        minimumControlMessages: 1,
        minimumVideoPackets: 1,
        minimumAudioPackets: 1,
        minimumDecodedVideoFrames: 1,
        minimumRenderedVideoFrames: 1,
        requireHostProcessingLatency: true
    ))
    await runtime.stop()

    #expect(metrics.controlMessagesObserved == 1)
    #expect(metrics.videoPacketsObserved == 1)
    #expect(metrics.audioPacketsObserved == 1)
    #expect(metrics.reorderedVideoPackets == 0)
    #expect(metrics.reorderedAudioPackets == 0)
    #expect(metrics.videoDiscontinuityEvents == 0)
    #expect(metrics.decodedVideoFrames == 1)
    #expect(metrics.renderedVideoFrames == 1)
    #expect(metrics.decodedAudioBuffers == 1)
    #expect(metrics.playedAudioBuffers == 1)
    #expect(metrics.averageVideoDecodeLatencyMs != nil)
    #expect(metrics.maxVideoDecodeLatencyMs != nil)
    #expect(metrics.averageVideoQueueLatencyMs != nil)
    #expect(metrics.maxVideoQueueLatencyMs != nil)
    #expect(metrics.averageVideoRenderSubmissionLatencyMs != nil)
    #expect(metrics.maxVideoRenderSubmissionLatencyMs != nil)
    #expect(approximatelyEqual(metrics.averageHostProcessingLatencyMs, 15.3))
    #expect(approximatelyEqual(metrics.maxHostProcessingLatencyMs, 15.3))
    #expect(metrics.averageAudioDecodeLatencyMs != nil)
    #expect(metrics.maxAudioDecodeLatencyMs != nil)
}

@Test
func runtimeSnapshotIncludesReorderAndDiscontinuityCounts() async throws {
    let session = MoonlightSession()
    try await session.attachVideoDecoder(RecordingVideoDecoder())
    try await session.attachRenderer(NullRenderer())
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x10, 0x20]))
    ]))
    try await session.attachAudioSink(NullAudioSink())
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    try await session.configureAudio(format: .init(sampleRate: 48_000, channelCount: 2))

    let videoSource = FixtureMediaPacketSource(packets: [
        makeRuntimeVideoPacket(
            sequenceNumber: 1,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 1,
            flags: VideoPacketHeader.startOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99])
        ),
        makeRuntimeVideoPacket(
            sequenceNumber: 10,
            timestamp: 33,
            streamPacketIndex: 10,
            frameIndex: 1,
            flags: VideoPacketHeader.endOfFrameFlag,
            payload: Data([0xAA])
        ),
        makeRuntimeVideoPacket(
            sequenceNumber: 11,
            timestamp: 66,
            streamPacketIndex: 11,
            frameIndex: 2,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 0xBB])
        )
    ])
    let audioSource = FixtureMediaPacketSource(packets: [
        makeRuntimeAudioPacket(sequenceNumber: 4, timestamp: 960, payload: Data([0xA1])),
        makeRuntimeAudioPacket(sequenceNumber: 7, timestamp: 3_840, payload: Data([0xB2]))
    ])

    let runtime = SessionRuntime(
        session: session,
        videoService: VideoIngestService(
            source: videoSource,
            depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 4)),
            pipeline: await session.mediaPipelineHandle()
        ),
        audioService: AudioIngestService(
            source: audioSource,
            depacketizer: SimpleAudioDepacketizer(reorderWindowSize: 2),
            pipeline: await session.mediaPipelineHandle()
        )
    )

    await runtime.start()
    let snapshot = await waitForRuntimeSnapshot(runtime) { snapshot in
        snapshot.reorderedAudioPackets >= 1 &&
        snapshot.videoDiscontinuityEvents >= 1 &&
        snapshot.missingVideoPackets >= 8 &&
        snapshot.missingAudioPackets >= 1 &&
        snapshot.audioConcealmentPackets >= 1
    }
    await runtime.stop()

    #expect(snapshot.reorderedVideoPackets == 0)
    #expect(snapshot.reorderedAudioPackets == 1)
    #expect(snapshot.videoDiscontinuityEvents == 1)
    #expect(snapshot.missingVideoPackets == 8)
    #expect(snapshot.missingAudioPackets == 1)
    #expect(snapshot.audioConcealmentPackets == 1)
}

@Test
func sessionRuntimeWarnsOnVideoDiscontinuity() async throws {
    let session = MoonlightSession()
    try await session.attachVideoDecoder(RecordingVideoDecoder())
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    let controlTransport = RecordingControlChannelTransport()
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let videoSource = FixtureMediaPacketSource(packets: [
        makeRuntimeVideoPacket(
            sequenceNumber: 1,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 1,
            flags: VideoPacketHeader.startOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99])
        ),
        makeRuntimeVideoPacket(
            sequenceNumber: 10,
            timestamp: 33,
            streamPacketIndex: 10,
            frameIndex: 1,
            flags: VideoPacketHeader.endOfFrameFlag,
            payload: Data([0xAA])
        )
    ])

    let runtime = SessionRuntime(
        session: session,
        controlService: control,
        videoService: VideoIngestService(
            source: videoSource,
            depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 4)),
            pipeline: await session.mediaPipelineHandle()
        )
    )

    let events = await session.events
    await runtime.start()
    let sawWarning = await containsSessionWarning(
        in: events,
        timeout: .seconds(1)
    ) { warning in
        warning.message.contains("requested a new keyframe")
    }

    await runtime.stop()
    let sent = await controlTransport.recordedSentPackets()
    #expect(sawWarning)
    #expect(sent.count == 1)
    guard sent.count == 1 else { return }
    #expect(sent[0].packet == Data([0x02, 0x03, 0x00, 0x00]))
    #expect(sent[0].channelID == ControlChannelID.urgent)
    #expect(sent[0].reliable)
}

@Test
func sessionRuntimeRequestsIDRAfterRecoverableVideoDecodeFailure() async throws {
    let session = MoonlightSession()
    try await session.attachVideoDecoder(FailingVideoDecoder(
        error: MoonlightError(.unsupportedOperation, message: "VideoToolbox decode failed: -12909")
    ))
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    let controlTransport = RecordingControlChannelTransport()
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let videoSource = FixtureMediaPacketSource(packets: [
        makeRuntimeVideoPacket(
            sequenceNumber: 1,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 1,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 0x99])
        )
    ])

    let runtime = SessionRuntime(
        session: session,
        controlService: control,
        videoService: VideoIngestService(
            source: videoSource,
            depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360))),
            pipeline: await session.mediaPipelineHandle()
        )
    )

    let events = await session.events
    await runtime.start()
    let sawWarning = await containsSessionWarning(
        in: events,
        timeout: .seconds(1)
    ) { warning in
        warning.message.contains("Video decoder rejected bad frame data; requested a new keyframe")
    }

    let snapshot = await runtime.snapshot()
    await runtime.stop()
    let sent = await controlTransport.recordedSentPackets()

    #expect(sawWarning)
    #expect(snapshot.recoverableVideoDecodeFailures == 1)
    #expect(!snapshot.unexpectedDisconnect)
    #expect(sent.count == 1)
    guard sent.count == 1 else { return }
    #expect(sent[0].packet == Data([0x02, 0x03, 0x00, 0x00]))
    #expect(sent[0].channelID == ControlChannelID.urgent)
    #expect(sent[0].reliable)
}

@Test
func sessionRuntimeSendsFrameFECStatusOnVideoDiscontinuity() async throws {
    let session = MoonlightSession()
    try await session.attachVideoDecoder(RecordingVideoDecoder())
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))
    let controlTransport = RecordingControlChannelTransport()
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let videoSource = FixtureMediaPacketSource(packets: [
        makeRuntimeVideoPacket(
            sequenceNumber: 10,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 44,
            flags: VideoPacketHeader.startOfFrameFlag,
            fecInfo: (UInt32(3) << 22) | (UInt32(0) << 12) | (UInt32(20) << 4),
            payload: Data(repeating: 0, count: 8)
        ),
        makeRuntimeVideoPacket(
            sequenceNumber: 12,
            timestamp: 33,
            streamPacketIndex: 3,
            frameIndex: 44,
            flags: VideoPacketHeader.endOfFrameFlag,
            fecInfo: (UInt32(3) << 22) | (UInt32(2) << 12) | (UInt32(20) << 4),
            payload: Data([0xAA])
        ),
        makeRuntimeVideoPacket(
            sequenceNumber: 20,
            timestamp: 66,
            streamPacketIndex: 1,
            frameIndex: 45,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data(repeating: 0, count: 8)
        )
    ])

    let runtime = SessionRuntime(
        session: session,
        controlService: control,
        videoService: VideoIngestService(
            source: videoSource,
            depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360), reorderWindowSize: 1)),
            pipeline: await session.mediaPipelineHandle()
        )
    )

    await runtime.start()
    var sent: [(packet: Data, channelID: UInt8, reliable: Bool)] = []
    for _ in 0..<40 {
        sent = await controlTransport.recordedSentPackets()
        if sent.count >= 2 {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    await runtime.stop()

    let fecStatus = try #require(sent.first {
        $0.channelID == ControlChannelID.generic && $0.reliable == false
    })
    #expect(fecStatus.packet.hexString == "02550000002C000C000B00010003000100020000140001")
    let idrRequest = try #require(sent.first {
        $0.channelID == ControlChannelID.urgent
    })
    #expect(idrRequest.packet == Data([0x02, 0x03, 0x00, 0x00]))
    #expect(idrRequest.reliable)
}

@Test
func sessionRuntimePublishesControlTransportMetrics() async throws {
    let transportMetrics = ControlTransportMetricsSnapshot(
        isConnected: true,
        roundTripTimeMs: 14,
        roundTripTimeVarianceMs: 4,
        packetLossRatio: 0.015,
        packetLossVarianceRatio: 0.003
    )
    let controlTransport = RecordingMetricsControlChannelTransport(
        receivedPackets: [try #require(Data(hexString: "015501001E0001"))],
        metrics: transportMetrics
    )
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let session = MoonlightSession()
    let metricStream = await session.metrics
    let runtime = SessionRuntime(session: session, controlService: control)

    await runtime.start()
    let published = await latestMetricSnapshot(
        from: metricStream,
        minimumControlMessages: 1,
        minimumVideoPackets: 0,
        minimumAudioPackets: 0
    )
    let runtimeSnapshot = await runtime.snapshot()
    await runtime.stop()

    #expect(published?.controlRoundTripTimeMs == 14)
    #expect(published?.controlRoundTripTimeVarianceMs == 4)
    #expect(published?.controlPacketLossRatio == 0.015)
    #expect(published?.controlPacketLossVarianceRatio == 0.003)
    #expect(runtimeSnapshot.controlRoundTripTimeMs == 14)
    #expect(runtimeSnapshot.controlPacketLossRatio == 0.015)
}

@Test
func sessionRuntimeRetriesTransientControlFailure() async throws {
    let session = MoonlightSession()
    let controlTransport = FlakyControlChannelTransport(steps: [
        .failure(MoonlightError(.unsupportedOperation, message: "temporary control failure")),
        .packet(try #require(Data(hexString: "0B0100000000010022114433"))),
        .end
    ])
    let control = ControlChannelService(transport: controlTransport, logger: TestLogger())
    let runtime = SessionRuntime(
        session: session,
        controlService: control,
        configuration: .init(maxReconnectAttempts: 1, reconnectBackoff: .milliseconds(1))
    )

    await runtime.start()
    try await Task.sleep(for: .milliseconds(30))
    let snapshot = await runtime.snapshot()
    let metrics = await latestMetricSnapshot(
        from: session.metrics,
        minimumControlMessages: 1,
        minimumVideoPackets: 0,
        minimumAudioPackets: 0
    )
    await runtime.stop()

    #expect(snapshot.reconnectAttempts == 1)
    #expect(snapshot.unexpectedDisconnect == false)
    #expect(metrics?.reconnectAttempts == 1)
    #expect(metrics?.controlMessagesObserved == 1)
}

@Test
func sessionRuntimeRetriesTransientMediaFailure() async throws {
    let session = MoonlightSession()
    try await session.attachVideoDecoder(RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 33, dimensions: CGSize(width: 640, height: 360), bytes: Data([0x01]))
    ]]))
    try await session.attachRenderer(NullRenderer())
    try await session.configureVideo(format: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)))

    let videoSource = FlakyMediaPacketSource(steps: [
        .failure(MoonlightError(.unsupportedOperation, message: "temporary video failure")),
        .packet(makeRuntimeVideoPacket(
            sequenceNumber: 1,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 1,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99])
        )),
        .end
    ])

    let runtime = SessionRuntime(
        session: session,
        videoService: VideoIngestService(
            source: videoSource,
            depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360))),
            pipeline: await session.mediaPipelineHandle()
        ),
        configuration: .init(maxReconnectAttempts: 1, reconnectBackoff: .milliseconds(1))
    )

    await runtime.start()
    let metrics = await latestMetricSnapshot(
        from: session.metrics,
        minimumControlMessages: 0,
        minimumVideoPackets: 1,
        minimumAudioPackets: 0
    )
    let snapshot = await runtime.snapshot()
    await runtime.stop()

    #expect(snapshot.reconnectAttempts == 1)
    #expect(snapshot.videoPacketsObserved == 1)
    #expect(snapshot.unexpectedDisconnect == false)
    #expect(metrics?.reconnectAttempts == 1)
    #expect(metrics?.videoPacketsObserved == 1)
}

@Test
func sessionRuntimeStopDoesNotReportCancellationAsUnexpectedDisconnect() async throws {
    let session = MoonlightSession()
    let video = VideoIngestService(
        source: CancellableMediaPacketSource(),
        depacketizer: SimpleVideoDepacketizer(configuration: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360))),
        pipeline: await session.mediaPipelineHandle()
    )
    let runtime = SessionRuntime(session: session, videoService: video)

    await runtime.start()
    try await Task.sleep(for: .milliseconds(10))
    await runtime.stop()

    let runtimeSnapshot = await runtime.snapshot()
    let sessionSnapshot = await session.currentMetricsSnapshot()
    #expect(!runtimeSnapshot.unexpectedDisconnect)
    #expect(!sessionSnapshot.unexpectedDisconnect)
}

private func waitForRuntimeSnapshot(
    _ runtime: SessionRuntime,
    matching predicate: (RuntimeObservationSnapshot) -> Bool
) async -> RuntimeObservationSnapshot {
    var latest = await runtime.snapshot()
    for _ in 0..<200 {
        if predicate(latest) {
            return latest
        }
        try? await Task.sleep(for: .milliseconds(5))
        latest = await runtime.snapshot()
    }
    return latest
}

private func latestMetricSnapshot(
    from stream: AsyncStream<SessionMetricsSnapshot>,
    minimumControlMessages: Int,
    minimumVideoPackets: Int,
    minimumAudioPackets: Int,
    minimumDecodedVideoFrames: Int = 0,
    minimumRenderedVideoFrames: Int = 0,
    requireHostProcessingLatency: Bool = false
) async -> SessionMetricsSnapshot? {
    await withTaskGroup(of: SessionMetricsSnapshot?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var latest: SessionMetricsSnapshot?
            while let snapshot = await iterator.next() {
                latest = snapshot
                if snapshot.controlMessagesObserved >= minimumControlMessages,
                   snapshot.videoPacketsObserved >= minimumVideoPackets,
                   snapshot.audioPacketsObserved >= minimumAudioPackets,
                   snapshot.decodedVideoFrames >= minimumDecodedVideoFrames,
                   snapshot.renderedVideoFrames >= minimumRenderedVideoFrames,
                   (!requireHostProcessingLatency || snapshot.averageHostProcessingLatencyMs != nil) {
                    return snapshot
                }
            }
            return latest
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
        }

        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private actor CancellableMediaPacketSource: MediaPacketSource {
    func receivePacket() async throws -> Data? {
        try await Task.sleep(for: .seconds(30))
        return nil
    }
}

private actor RecordingControllerFeedbackSink: ControllerFeedbackSink {
    private var feedback: [ControllerFeedback] = []

    func apply(_ feedback: ControllerFeedback) async throws {
        self.feedback.append(feedback)
    }

    func recordedFeedback() -> [ControllerFeedback] {
        feedback
    }
}

private struct FailingControllerFeedbackSink: ControllerFeedbackSink {
    func apply(_ feedback: ControllerFeedback) async throws {
        _ = feedback
        throw MoonlightError(.unsupportedOperation, message: "feedback sink test failure")
    }
}

private func containsSessionWarning(
    in stream: AsyncStream<SessionEvent>,
    timeout: Duration,
    matching predicate: @escaping @Sendable (MoonlightWarning) -> Bool
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            while let event = await iterator.next() {
                if case .warning(let warning) = event, predicate(warning) {
                    return true
                }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }

        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private func collectControllerFeedbackEvents(
    from stream: AsyncStream<SessionEvent>,
    count: Int,
    timeout: Duration = .seconds(1)
) async -> [ControllerFeedback] {
    await withTaskGroup(of: [ControllerFeedback].self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var received: [ControllerFeedback] = []
            while received.count < count, let event = await iterator.next() {
                if case .controllerFeedback(let feedback) = event {
                    received.append(feedback)
                }
            }
            return received
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return []
        }

        let result = await group.next() ?? []
        group.cancelAll()
        return result
    }
}

private func collectHDRModeEvents(
    from stream: AsyncStream<SessionEvent>,
    count: Int,
    timeout: Duration = .seconds(1)
) async -> [HDRModeUpdate] {
    await withTaskGroup(of: [HDRModeUpdate].self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var received: [HDRModeUpdate] = []
            while received.count < count, let event = await iterator.next() {
                if case .hdrModeChanged(let update) = event {
                    received.append(update)
                }
            }
            return received
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return []
        }

        let result = await group.next() ?? []
        group.cancelAll()
        return result
    }
}

private func approximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
    guard let lhs else {
        return false
    }
    return abs(lhs - rhs) <= tolerance
}

private func makeRuntimeVideoPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    streamPacketIndex: UInt32,
    frameIndex: UInt32,
    flags: UInt8,
    multiFecBlocks: UInt8 = 0,
    fecInfo: UInt32 = 0,
    payload: Data
) -> Data {
    var data = Data()
    data.append(0x80)
    data.append(0x60)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,1])
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: streamPacketIndex),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 8),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 16),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 24),
        UInt8(truncatingIfNeeded: frameIndex),
        UInt8(truncatingIfNeeded: frameIndex >> 8),
        UInt8(truncatingIfNeeded: frameIndex >> 16),
        UInt8(truncatingIfNeeded: frameIndex >> 24),
        flags,
        0,
        0,
        multiFecBlocks,
        UInt8(truncatingIfNeeded: fecInfo),
        UInt8(truncatingIfNeeded: fecInfo >> 8),
        UInt8(truncatingIfNeeded: fecInfo >> 16),
        UInt8(truncatingIfNeeded: fecInfo >> 24)
    ])
    data.append(payload)
    return data
}

private func makeRuntimeAudioPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    payload: Data
) -> Data {
    var data = Data()
    data.append(0x80)
    data.append(0x61)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,2])
    data.append(payload)
    return data
}
