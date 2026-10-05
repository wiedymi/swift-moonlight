#if canImport(AVFoundation)
import AVFoundation
import Foundation

public actor SystemAudioSink: AudioSink {
    private static let startDurationSeconds = 0.02
    private static let maxQueuedDurationSeconds = 0.12

    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private var preparedFormat: AVAudioFormat?
    // The player sample clock measures consumed audio without delayed actor callbacks.
    private var scheduledEndFrame: AVAudioFramePosition = 0

    public init() {
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
    }

    init(engine: AVAudioEngine, playerNode: AVAudioPlayerNode) {
        self.engine = engine
        self.playerNode = playerNode
    }

    public func prepare(format: AudioFormat) async throws {
        playerNode.stop()
        scheduledEndFrame = 0
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
        preparedFormat = avFormat
    }

    public func play(_ buffer: PCMBuffer) async -> AudioPlaybackResult {
        do {
            guard let preparedFormat else {
                return .dropped
            }

            guard buffer.sampleRate > 0, buffer.frameCount > 0 else {
                return .dropped
            }
            guard buffer.sampleRate == Int(preparedFormat.sampleRate),
                  buffer.channelCount == Int(preparedFormat.channelCount) else { return .dropped }
            let maxQueuedFrames = AVAudioFramePosition(preparedFormat.sampleRate * Self.maxQueuedDurationSeconds)
            let startFrames = AVAudioFramePosition(preparedFormat.sampleRate * Self.startDurationSeconds)
            let renderedFrame = playerNode.lastRenderTime.flatMap {
                playerNode.isPlaying && ($0.isSampleTimeValid || $0.isHostTimeValid)
                    ? playerNode.playerTime(forNodeTime: $0) : nil
            }.map { max(0, $0.sampleTime) } ?? 0
            var queuedFrames = max(0, scheduledEndFrame - renderedFrame)
            if playerNode.isPlaying, queuedFrames == 0 {
                // A true gap needs the same small buffer as the initial start.
                playerNode.stop()
                scheduledEndFrame = 0
                queuedFrames = 0
            }
            let frames = AVAudioFramePosition(buffer.frameCount)
            let (endFrame, overflow) = scheduledEndFrame.addingReportingOverflow(frames)
            guard !overflow, frames <= maxQueuedFrames, queuedFrames <= maxQueuedFrames - frames else {
                return .dropped
            }

            let pcmBuffer = try PCMBufferBridge.makeAVAudioPCMBuffer(from: buffer, format: preparedFormat)
            playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
            scheduledEndFrame = endFrame
            if !playerNode.isPlaying, queuedFrames + frames >= startFrames {
                playerNode.play()
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
        scheduledEndFrame = 0
    }

}
#endif
