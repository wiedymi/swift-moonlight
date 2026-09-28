import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func defaultStreamConfigurationPrefersHardwareDecode() {
    let configuration = StreamConfiguration.default1080p60

    #expect(configuration.resolution.width == 1920)
    #expect(configuration.resolution.height == 1080)
    #expect(configuration.frameRate == 60)
    #expect(configuration.bitrateKbps == 20_000)
    #expect(configuration.preferredDecodeMode == .hardwareFirst)
    #expect(configuration.audioMode == .stereo)
    #expect(configuration.videoCodecPreference == [.hevc, .h264])
    #expect(!configuration.playAudioOnHost)
    #expect(!configuration.requestContinuousAudio)
    #expect(configuration.attachedGamepadMask == 0)
    #expect(!configuration.persistGamepadsAfterDisconnect)
    do {
        try configuration.validate()
    } catch {
        Issue.record("Default stream configuration should validate: \(error)")
    }
}

@Test
func streamConfigurationRejectsInvalidResolution() {
    var configuration = StreamConfiguration.default1080p60
    configuration.resolution = CGSize(width: 0, height: 1080)

    expectCapabilityMismatch {
        try configuration.validate()
    }
}

@Test
func streamConfigurationRejectsInvalidFrameRate() {
    var configuration = StreamConfiguration.default1080p60
    configuration.frameRate = 0

    expectCapabilityMismatch {
        try configuration.validate()
    }
}

@Test
func streamConfigurationRejectsInvalidBitrate() {
    var configuration = StreamConfiguration.default1080p60
    configuration.bitrateKbps = 0

    expectCapabilityMismatch {
        try configuration.validate()
    }
}

@Test
func streamConfigurationRejectsEmptyCodecPreference() {
    var configuration = StreamConfiguration.default1080p60
    configuration.videoCodecPreference = []

    expectCapabilityMismatch {
        try configuration.validate()
    }
}

@Test
func streamConfigurationRejectsNegativeAttachedGamepadMask() {
    var configuration = StreamConfiguration.default1080p60
    configuration.attachedGamepadMask = -1

    expectCapabilityMismatch {
        try configuration.validate()
    }
}

@Test
func hostCapabilitiesInferSupportedVideoCodecsFromCodecFlags() {
    let h264Only = HostCapabilities.inferred(for: .sunshine, codecSupportFlags: 0x0000_0001)
    let hdrCapable = HostCapabilities.inferred(for: .apollo, codecSupportFlags: 0x0002_0200)

    #expect(h264Only.supportedVideoCodecs == [.h264])
    #expect(!h264Only.supportsHDR)
    #expect(hdrCapable.supportedVideoCodecs == [.av1, .hevc])
    #expect(hdrCapable.supportsHDR)
}

@Test
func streamConfigurationRejectsHostUnsupportedCodecPreference() {
    let host = validationHost(capabilities: .init(supportedVideoCodecs: [.h264]))
    var configuration = StreamConfiguration.default1080p60
    configuration.videoCodecPreference = [.hevc]

    expectCapabilityMismatch {
        try configuration.validate(against: host)
    }
}

@Test
func streamConfigurationRejectsHDRWhenHostDoesNotAdvertiseHDR() {
    let host = validationHost(capabilities: .init(supportedVideoCodecs: [.hevc], supportsHDR: false))
    var configuration = StreamConfiguration.default1080p60
    configuration.dynamicRange = .hdr

    expectCapabilityMismatch {
        try configuration.validate(against: host)
    }
}

@Test
func streamConfigurationRejectsAbove4KWhenOnlyH264IsSupported() {
    let host = validationHost(capabilities: .init(supportedVideoCodecs: [.h264]))
    var configuration = StreamConfiguration.default1080p60
    configuration.resolution = CGSize(width: 5120, height: 2880)
    configuration.videoCodecPreference = [.h264]

    expectCapabilityMismatch {
        try configuration.validate(against: host)
    }
}

@Test
func sessionLifecycleMachineRejectsInvalidTransition() {
    var machine = SessionLifecycleMachine()

    do {
        try machine.transition(to: .streaming)
        Issue.record("Expected invalid transition to throw")
    } catch let error as MoonlightError {
        #expect(error.code == .invalidStateTransition)
        #expect(machine.state == .idle)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func sessionLifecycleMachineAllowsHappyPath() throws {
    var machine = SessionLifecycleMachine()

    try machine.transition(to: .discovering)
    try machine.transition(to: .pairing)
    try machine.transition(to: .paired)
    try machine.transition(to: .launching)
    try machine.transition(to: .connecting)
    try machine.transition(to: .streaming)
    try machine.transition(to: .stopping)
    try machine.transition(to: .stopped)

    #expect(machine.state == .stopped)
}

@Test
func sessionMetricsSnapshotRoundTripsThroughJSON() throws {
    let snapshot = SessionMetricsSnapshot(
        sessionOpenDurationMs: 42,
        controlRoundTripTimeMs: 11,
        controlRoundTripTimeVarianceMs: 3,
        controlPacketLossRatio: 0.01,
        controlPacketLossVarianceRatio: 0.002,
        inputEventsSent: 2,
        inputPacketsSent: 3,
        rendererAttachments: 1,
        audioSinkAttachments: 1,
        establishedChannelCount: 4,
        controlMessagesObserved: 5,
        videoPacketsObserved: 6,
        audioPacketsObserved: 7,
        audioConcealmentPackets: 1,
        missingVideoPackets: 2,
        missingAudioPackets: 3,
        reorderedVideoPackets: 4,
        reorderedAudioPackets: 5,
        videoDiscontinuityEvents: 6,
        videoFrameFECStatusReports: 7,
        recoverableVideoDecodeFailures: 8,
        reconnectAttempts: 1,
        decodedVideoFrames: 8,
        renderedVideoFrames: 8,
        decodedAudioBuffers: 9,
        playedAudioBuffers: 9,
        averageVideoDecodeLatencyMs: 1.5,
        maxVideoDecodeLatencyMs: 2.5,
        averageHostProcessingLatencyMs: 3.5,
        maxHostProcessingLatencyMs: 4.5,
        averageAudioDecodeLatencyMs: 0.5,
        maxAudioDecodeLatencyMs: 0.75,
        averageInputQueueLatencyMs: 0.25,
        maxInputQueueLatencyMs: 0.5,
        averageInputTransportLatencyMs: 0.75,
        maxInputTransportLatencyMs: 1.25,
        audioUnderrunEvents: 2,
        unexpectedDisconnect: true
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SessionMetricsSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

private func expectCapabilityMismatch(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected capability mismatch")
    } catch let error as MoonlightError {
        #expect(error.code == .capabilityMismatch)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

private func validationHost(capabilities: HostCapabilities) -> MoonlightHost {
    MoonlightHost(
        id: HostID(),
        name: "Validation Host",
        endpoint: .init(address: "127.0.0.1", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: capabilities
    )
}
