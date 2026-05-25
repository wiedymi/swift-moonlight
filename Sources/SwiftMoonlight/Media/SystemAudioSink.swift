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
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(buffer.frameCount)
        ) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create AVAudioPCMBuffer")
        }

        pcmBuffer.frameLength = AVAudioFrameCount(buffer.frameCount)

        let byteCount = Int(pcmBuffer.frameLength) * buffer.bytesPerFrame
        guard byteCount <= buffer.data.count else {
            throw MoonlightError(.unsupportedOperation, message: "PCM buffer data is shorter than declared frame count")
        }

        let expectedBytesPerFrame = max(buffer.channelCount, 1) * MemoryLayout<Int16>.size
        guard format.commonFormat == .pcmFormatInt16,
              format.isInterleaved,
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
        preparedFormat = avFormat
        queuedFrameCount = 0
        engine.prepare()

        if !engine.isRunning {
            try engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    public func play(_ buffer: PCMBuffer) async {
        do {
            if preparedFormat == nil {
                try await prepare(format: .init(sampleRate: buffer.sampleRate, channelCount: buffer.channelCount))
            }
            guard let preparedFormat else {
                return
            }

            let queuedDuration = Double(queuedFrameCount) / Double(max(buffer.sampleRate, 1))
            if queuedDuration > Self.maxQueuedDurationSeconds {
                return
            }

            let pcmBuffer = try PCMBufferBridge.makeAVAudioPCMBuffer(from: buffer, format: preparedFormat)
            let scheduledFrameCount = Int(pcmBuffer.frameLength)
            queuedFrameCount += scheduledFrameCount

            playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                Task {
                    await self?.consumeQueuedFrames(scheduledFrameCount)
                }
            }
        } catch {
            return
        }
    }

    public func teardown() async {
        playerNode.stop()
        engine.stop()
        preparedFormat = nil
        queuedFrameCount = 0
    }

    private func consumeQueuedFrames(_ frameCount: Int) {
        queuedFrameCount = max(0, queuedFrameCount - frameCount)
    }
}
#endif
