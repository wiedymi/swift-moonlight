#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func pcmBufferBridgeCreatesInterleavedInt16PCMFormat() throws {
    let format = try PCMBufferBridge.makeAVAudioFormat(from: .init(sampleRate: 48_000, channelCount: 2))

    #expect(format.sampleRate == 48_000)
    #expect(format.channelCount == 2)
    #expect(format.commonFormat == .pcmFormatInt16)
    #expect(format.isInterleaved)
}

@Test
func pcmBufferBridgeCopiesInterleavedInt16PCMBytesIntoPlaybackBuffer() throws {
    let source = PCMBuffer(
        sampleRate: 48_000,
        channelCount: 2,
        frameCount: 2,
        bytesPerFrame: 4,
        data: Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00])
    )

    let format = try PCMBufferBridge.makeAVAudioFormat(from: .init(sampleRate: 48_000, channelCount: 2))
    let buffer = try PCMBufferBridge.makeAVAudioPCMBuffer(from: source, format: format)
    let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let copiedBytes = Data(
        bytes: audioBuffers[0].mData!,
        count: Int(audioBuffers[0].mDataByteSize)
    )

    #expect(buffer.frameLength == 2)
    #expect(audioBuffers.count == 1)
    #expect(copiedBytes == source.data)
}
#endif
