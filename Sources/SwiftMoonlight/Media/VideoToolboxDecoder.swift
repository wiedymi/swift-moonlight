#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public actor VideoToolboxDecoder: VideoDecoder {
    private var configuredFormat: VideoFormat?
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var activeParameterSets: [Data] = []

    public init() {}

    public func configure(format: VideoFormat) async throws {
        invalidateSession()
        configuredFormat = nil
        formatDescription = nil
        activeParameterSets = []

        if format.codec == .av1 {
            throw MoonlightError(.unsupportedOperation, message: "AV1 VideoToolbox decode is not implemented yet")
        }

        configuredFormat = format
    }

    public func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        guard let configuredFormat else {
            throw MoonlightError(.unsupportedOperation, message: "Video decoder must be configured before decode")
        }

        let parameterSets = frame.parameterSets.isEmpty ? AnnexBBitstream.codecParameterSets(from: frame.payload, codec: frame.codec) : frame.parameterSets
        if !parameterSets.isEmpty && parameterSets != activeParameterSets {
            activeParameterSets = parameterSets
            try rebuildSession(codec: frame.codec, parameterSets: parameterSets, format: configuredFormat)
        }

        guard let session, let formatDescription else {
            return []
        }

        let sampleData = AnnexBBitstream.lengthPrefixedSample(from: frame.payload)
        let sampleBuffer = try makeSampleBuffer(
            sampleData: sampleData,
            formatDescription: formatDescription,
            timestamp: frame.timestamp
        )

        let decodedFrame = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DecodedVideoFrame, Error>) in
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                infoFlagsOut: &infoFlags
            ) { status, _, imageBuffer, presentationTimeStamp, _ in
                if status != noErr {
                    continuation.resume(throwing: MoonlightError(.unsupportedOperation, message: "VideoToolbox decode failed: \(status)"))
                    return
                }

                guard let imageBuffer else {
                    continuation.resume(returning: DecodedVideoFrame(
                        timestamp: frame.timestamp,
                        dimensions: configuredFormat.dimensions,
                        bytes: nil
                    ))
                    return
                }

                let timestampValue = presentationTimeStamp.isValid ? UInt64(max(0, presentationTimeStamp.value)) : frame.timestamp
                continuation.resume(returning: DecodedVideoFrame(
                    timestamp: timestampValue,
                    dimensions: configuredFormat.dimensions,
                    pixelBuffer: PixelBufferBox(imageBuffer)
                ))
            }

            if status != noErr {
                continuation.resume(throwing: MoonlightError(.unsupportedOperation, message: "VideoToolbox submit failed: \(status)"))
            }
        }

        return [decodedFrame]
    }

    public func flush() async throws -> [DecodedVideoFrame] {
        if let session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        return []
    }

    private func rebuildSession(codec: VideoCodec, parameterSets: [Data], format: VideoFormat) throws {
        invalidateSession()
        let description = try VideoFormatDescriptionFactory.makeDescription(codec: codec, parameterSets: parameterSets)
        formatDescription = description

        let attrs = Self.imageBufferAttributes(for: format)

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create VideoToolbox session: \(status)")
        }

        session = newSession
    }

    static func imageBufferAttributes(for format: VideoFormat) -> NSDictionary {
        let pixelFormat: OSType = switch format.dynamicRange {
        case .sdr:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hdr:
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }

        return [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
    }

    private func makeSampleBuffer(
        sampleData: Data,
        formatDescription: CMVideoFormatDescription,
        timestamp: UInt64
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let status = sampleData.withUnsafeBytes { rawBuffer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: sampleData.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: sampleData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == noErr, let blockBuffer else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create CMBlockBuffer: \(status)")
        }

        let replaceStatus = sampleData.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard replaceStatus == noErr else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to fill CMBlockBuffer: \(replaceStatus)")
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = sampleData.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create CMSampleBuffer: \(sampleStatus)")
        }

        return sampleBuffer
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }
}
#endif
