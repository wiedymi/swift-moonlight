import Foundation
import Darwin

public enum AnnexBBitstream {
    public static func splitNALUnits(in data: Data) -> [Data] {
        data.withUnsafeBytes { bytes in
            nalUnitRanges(in: bytes).map { Data(bytes[$0]) }
        }
    }

    public static func codecParameterSets(from data: Data, codec: VideoCodec) -> [Data] {
        data.withUnsafeBytes { bytes in
            nalUnitRanges(in: bytes).compactMap { range in
                isParameterSet(bytes[range.lowerBound], codec: codec) ? Data(bytes[range]) : nil
            }
        }
    }

    public static func containsParameterSets(_ data: Data, codec: VideoCodec) -> Bool {
        data.withUnsafeBytes { bytes in
            nalUnitRanges(in: bytes).contains { isParameterSet(bytes[$0.lowerBound], codec: codec) }
        }
    }

    public static func lengthPrefixedSample(from data: Data) -> Data {
        data.withUnsafeBytes { bytes in
            let ranges = nalUnitRanges(in: bytes)
            guard !ranges.isEmpty, ranges.allSatisfy({ $0.count <= UInt32.max }) else { return data }
            var output = Data()
            output.reserveCapacity(data.count)
            for range in ranges {
                var length = UInt32(range.count).bigEndian
                withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
                output.append(contentsOf: bytes[range])
            }
            return output
        }
    }

    private static func isParameterSet(_ first: UInt8, codec: VideoCodec) -> Bool {
        switch codec {
        case .h264:
            let type = first & 0x1F
            return type == 7 || type == 8
        case .hevc:
            let type = (first & 0x7E) >> 1
            return type == 32 || type == 33 || type == 34
        case .av1:
            return false
        }
    }

    // Offsets refer to this temporary raw buffer, so Data slices need no rebasing.
    private static func nalUnitRanges(in bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        guard let base = bytes.baseAddress, bytes.count >= 3 else { return [] }
        var ranges: [Range<Int>] = []
        var unitStart: Int?
        var index = 0
        while bytes.count - index >= 3 {
            // Encoded payloads rarely contain zero. libc can skip nonzero bytes in bulk.
            if bytes[index] != 0 {
                guard let zero = memchr(base.advanced(by: index), 0, bytes.count - index) else { break }
                index = base.distance(to: zero)
                guard bytes.count - index >= 3 else { break }
            }
            let startCodeLength: Int
            if bytes[index + 1] == 0, bytes[index + 2] == 1 {
                startCodeLength = 3
            } else if bytes.count - index >= 4, bytes[index + 1] == 0,
                      bytes[index + 2] == 0, bytes[index + 3] == 1 {
                startCodeLength = 4
            } else {
                index += 1
                continue
            }
            if let unitStart, unitStart < index { ranges.append(unitStart..<index) }
            index += startCodeLength
            unitStart = index
        }
        if let unitStart, unitStart < bytes.count { ranges.append(unitStart..<bytes.count) }
        return ranges
    }
}

#if canImport(CoreMedia)
import CoreMedia

enum VideoFormatDescriptionFactory {
    static func makeDescription(codec: VideoCodec, parameterSets: [Data]) throws -> CMVideoFormatDescription {
        switch codec {
        case .h264:
            guard parameterSets.count >= 2 else {
                throw MoonlightError(.unsupportedOperation, message: "H.264 decode requires SPS and PPS parameter sets")
            }

            let sps = [UInt8](parameterSets[0])
            let pps = [UInt8](parameterSets[1])
            return try sps.withUnsafeBufferPointer { spsPtr in
                try pps.withUnsafeBufferPointer { ppsPtr in
                    let pointers: [UnsafePointer<UInt8>] = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                    let sizes: [Int] = [sps.count, pps.count]
                    return try pointers.withUnsafeBufferPointer { pointerBuffer in
                        try sizes.withUnsafeBufferPointer { sizeBuffer in
                            var description: CMFormatDescription?
                            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: pointerBuffer.baseAddress!,
                                parameterSetSizes: sizeBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &description
                            )
                            guard status == noErr, let typed = description else {
                                throw MoonlightError(.unsupportedOperation, message: "Failed to create H.264 format description: \(status)")
                            }
                            return typed
                        }
                    }
                }
            }

        case .hevc:
            guard parameterSets.count >= 3 else {
                throw MoonlightError(.unsupportedOperation, message: "HEVC decode requires VPS, SPS, and PPS parameter sets")
            }

            let vps = [UInt8](parameterSets[0])
            let sps = [UInt8](parameterSets[1])
            let pps = [UInt8](parameterSets[2])
            return try vps.withUnsafeBufferPointer { vpsPtr in
                try sps.withUnsafeBufferPointer { spsPtr in
                    try pps.withUnsafeBufferPointer { ppsPtr in
                        let pointers: [UnsafePointer<UInt8>] = [vpsPtr.baseAddress!, spsPtr.baseAddress!, ppsPtr.baseAddress!]
                        let sizes: [Int] = [vps.count, sps.count, pps.count]
                        return try pointers.withUnsafeBufferPointer { pointerBuffer in
                            try sizes.withUnsafeBufferPointer { sizeBuffer in
                                var description: CMFormatDescription?
                                let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: pointerBuffer.baseAddress!,
                                    parameterSetSizes: sizeBuffer.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &description
                                )
                                guard status == noErr, let typed = description else {
                                    throw MoonlightError(.unsupportedOperation, message: "Failed to create HEVC format description: \(status)")
                                }
                                return typed
                            }
                        }
                    }
                }
            }

        case .av1:
            throw MoonlightError(.unsupportedOperation, message: "AV1 VideoToolbox decode is not implemented yet")
        }
    }
}
#endif
