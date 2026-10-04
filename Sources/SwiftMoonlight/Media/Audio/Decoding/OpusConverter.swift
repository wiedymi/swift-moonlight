#if canImport(AudioToolbox)
import AudioToolbox
import Foundation

// The actor owns this box exclusively. All converter calls and synchronous input
// callbacks finish before the actor suspends; disposal cannot overlap decoding.
// Input storage stays alive until the next callback, reset, or converter disposal.
final class OpusConverter: @unchecked Sendable {
    let reference: AudioConverterRef
    var configuration: OpusStreamConfiguration
    var retainedPacket: OpusPacketStorage?

    init(reference: AudioConverterRef, configuration: OpusStreamConfiguration) {
        self.reference = reference
        self.configuration = configuration
    }

    deinit { AudioConverterDispose(reference) }
}

// AudioConverter may retain input pointers after FillComplexBuffer returns.
// NSData provides stable immutable bytes; the description also has stable storage.
final class OpusPacketStorage {
    private let payload: NSData
    private let channelCount: UInt32
    let description: UnsafeMutablePointer<AudioStreamPacketDescription>

    init(payload: Data, frameCount: Int, channelCount: Int) {
        self.payload = payload as NSData
        self.channelCount = UInt32(channelCount)
        description = .allocate(capacity: 1)
        description.initialize(to: AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: UInt32(frameCount), mDataByteSize: UInt32(payload.count)
        ))
    }

    var buffer: AudioBuffer {
        AudioBuffer(mNumberChannels: channelCount, mDataByteSize: UInt32(payload.length),
                    mData: UnsafeMutableRawPointer(mutating: payload.bytes))
    }

    deinit {
        description.deinitialize(count: 1)
        description.deallocate()
    }
}

struct OpusConverterInput {
    var packet: OpusPacketStorage?
    let converter: OpusConverter
}

// A nonzero result means this call has no further input, rather than end of stream.
private let opusInputExhausted: OSStatus = 1

func supplyOpusPacket(
    _ converter: AudioConverterRef,
    _ packetCount: UnsafeMutablePointer<UInt32>,
    _ buffers: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    packetCount.pointee = 0
    guard let context else { return kAudio_ParamError }
    let input = context.assumingMemoryBound(to: OpusConverterInput.self)
    // A new callback ends the previous input buffer's required lifetime.
    input.pointee.converter.retainedPacket = nil
    guard let packet = input.pointee.packet else { return opusInputExhausted }
    input.pointee.converter.retainedPacket = packet
    input.pointee.packet = nil
    packetCount.pointee = 1
    buffers.pointee.mNumberBuffers = 1
    buffers.pointee.mBuffers = packet.buffer
    descriptions?.pointee = packet.description
    return noErr
}
#endif
