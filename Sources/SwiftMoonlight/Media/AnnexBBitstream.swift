import Foundation

public enum AnnexBBitstream {
    public static func splitNALUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            return []
        }

        let starts = startCodeRanges(in: bytes)
        guard !starts.isEmpty else {
            return []
        }

        var units: [Data] = []
        units.reserveCapacity(starts.count)

        for (index, range) in starts.enumerated() {
            let unitStart = range.upperBound
            let unitEnd = index + 1 < starts.count ? starts[index + 1].lowerBound : bytes.count
            guard unitStart < unitEnd else {
                continue
            }
            units.append(Data(bytes[unitStart..<unitEnd]))
        }

        return units
    }

    public static func codecParameterSets(from data: Data, codec: VideoCodec) -> [Data] {
        splitNALUnits(in: data).filter { unit in
            guard let first = unit.first else {
                return false
            }

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
    }

    public static func containsParameterSets(_ data: Data, codec: VideoCodec) -> Bool {
        !codecParameterSets(from: data, codec: codec).isEmpty
    }

    public static func lengthPrefixedSample(from data: Data) -> Data {
        let units = splitNALUnits(in: data)
        guard !units.isEmpty else {
            return data
        }

        var output = Data()
        for unit in units {
            output.append(lengthPrefix(for: unit.count))
            output.append(unit)
        }
        return output
    }

    private static func startCodeRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0

        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    ranges.append(index..<(index + 4))
                    index += 4
                    continue
                }
                if bytes[index + 2] == 1 {
                    ranges.append(index..<(index + 3))
                    index += 3
                    continue
                }
            }
            index += 1
        }

        return ranges
    }

    private static func lengthPrefix(for count: Int) -> Data {
        Data([
            UInt8(truncatingIfNeeded: count >> 24),
            UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8),
            UInt8(truncatingIfNeeded: count)
        ])
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
