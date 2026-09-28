#if canImport(AVFoundation)
import AVFoundation
import Foundation

enum PCMBufferBridge {
    static func makeAVAudioFormat(from format: AudioFormat) throws -> AVAudioFormat {
        let channelLayout = makeChannelLayout(channelCount: format.channelCount)
        let audioFormat: AVAudioFormat?
        if let channelLayout {
            audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(format.sampleRate),
                interleaved: true,
                channelLayout: channelLayout
            )
        } else {
            audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(format.sampleRate),
                channels: AVAudioChannelCount(format.channelCount),
                interleaved: true
            )
        }

        guard let audioFormat else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create AVAudioFormat for PCM playback")
        }
        return audioFormat
    }

    static func makeAVAudioPCMBuffer(from buffer: PCMBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.frameCount >= 0, buffer.frameCount <= UInt32.max else {
            throw MoonlightError(.unsupportedOperation, message: "PCM frame count is out of range")
        }
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(buffer.frameCount)
        ) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create AVAudioPCMBuffer")
        }

        pcmBuffer.frameLength = AVAudioFrameCount(buffer.frameCount)

        let (byteCount, byteCountOverflow) = Int(pcmBuffer.frameLength).multipliedReportingOverflow(by: buffer.bytesPerFrame)
        guard !byteCountOverflow, byteCount >= 0, byteCount <= buffer.data.count, byteCount <= UInt32.max else {
            throw MoonlightError(.unsupportedOperation, message: "PCM buffer data is shorter than declared frame count")
        }

        let (expectedBytesPerFrame, channelCountOverflow) = max(buffer.channelCount, 1).multipliedReportingOverflow(by: MemoryLayout<Int16>.size)
        guard format.commonFormat == .pcmFormatInt16,
              format.isInterleaved,
              !channelCountOverflow,
              buffer.bytesPerFrame == expectedBytesPerFrame
        else {
            throw MoonlightError(.unsupportedOperation, message: "Unsupported PCM layout for playback bridge")
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        guard audioBuffers.count == 1,
              let destination = audioBuffers[0].mData
        else {
            throw MoonlightError(.unsupportedOperation, message: "Interleaved AVAudioPCMBuffer storage is unavailable")
        }

        buffer.data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: byteCount)
        audioBuffers[0].mDataByteSize = UInt32(byteCount)

        return pcmBuffer
    }

    private static func makeChannelLayout(channelCount: Int) -> AVAudioChannelLayout? {
        switch channelCount {
        case 2:
            return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)
        case 6:
            return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)
        case 8:
            return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_7_1_A)
        default:
            return nil
        }
    }
}

public actor SystemAudioSink: AudioSink {
    private static let maxQueuedDurationSeconds = 0.04

    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private var preparedFormat: AVAudioFormat?
    private var queuedFrameCount = 0
    private var playbackID = UUID()

    public init() {
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
    }

    public func prepare(format: AudioFormat) async throws {
        let avFormat = try PCMBufferBridge.makeAVAudioFormat(from: format)

        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
        engine.prepare()

        if !engine.isRunning {
            try engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        preparedFormat = avFormat
        queuedFrameCount = 0
        playbackID = UUID()
    }

    public func play(_ buffer: PCMBuffer) async -> AudioPlaybackResult {
        do {
            if preparedFormat == nil {
                try await prepare(format: .init(sampleRate: buffer.sampleRate, channelCount: buffer.channelCount))
            }
            guard let preparedFormat else {
                return .dropped
            }

            guard buffer.sampleRate > 0, buffer.frameCount > 0 else {
                return .dropped
            }
            let maxQueuedFrames = Int(Double(buffer.sampleRate) * Self.maxQueuedDurationSeconds)
            if buffer.frameCount > maxQueuedFrames || queuedFrameCount > maxQueuedFrames - buffer.frameCount {
                return .dropped
            }

            let pcmBuffer = try PCMBufferBridge.makeAVAudioPCMBuffer(from: buffer, format: preparedFormat)
            let scheduledFrameCount = Int(pcmBuffer.frameLength)
            queuedFrameCount += scheduledFrameCount
            let scheduledPlaybackID = playbackID

            playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataRendered) { [weak self] _ in
                Task {
                    await self?.consumeQueuedFrames(scheduledFrameCount, playbackID: scheduledPlaybackID)
                }
            }
            return .accepted
        } catch {
            return .dropped
        }
    }

    public func teardown() async {
        playerNode.stop()
        engine.stop()
        preparedFormat = nil
        queuedFrameCount = 0
        playbackID = UUID()
    }

    private func consumeQueuedFrames(_ frameCount: Int, playbackID: UUID) {
        guard playbackID == self.playbackID else { return }
        queuedFrameCount = max(0, queuedFrameCount - frameCount)
    }
}
#endif
