import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func splitsAnnexBNALUnits() {
    let bitstream = Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0xAA,
        0x00, 0x00, 0x01, 0x68, 0xBB,
        0x00, 0x00, 0x01, 0x65, 0xCC
    ])

    let units = AnnexBBitstream.splitNALUnits(in: bitstream)

    #expect(units.map(\.hexString) == ["67AA", "68BB", "65CC"])
}

@Test
func extractsH264ParameterSets() {
    let bitstream = Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00,
        0x00, 0x00, 0x01, 0x68, 0xEE,
        0x00, 0x00, 0x01, 0x65, 0x88
    ])

    let sets = AnnexBBitstream.codecParameterSets(from: bitstream, codec: .h264)

    #expect(sets.map(\.hexString) == ["6764", "68EE"])
}

@Test
func extractsHEVCParameterSets() {
    let bitstream = Data([
        0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
        0x00, 0x00, 0x01, 0x42, 0x01,
        0x00, 0x00, 0x01, 0x44, 0x01,
        0x00, 0x00, 0x01, 0x26, 0x01
    ])

    let sets = AnnexBBitstream.codecParameterSets(from: bitstream, codec: .hevc)

    #expect(sets.map(\.hexString) == ["4001", "4201", "4401"])
}

@Test
func convertsAnnexBToLengthPrefixedSample() {
    let bitstream = Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0xAA,
        0x00, 0x00, 0x01, 0x68, 0xBB
    ])

    let sample = AnnexBBitstream.lengthPrefixedSample(from: bitstream)

    #expect(sample.hexString == "0000000267AA0000000268BB")
}

@Test
func splitsRepeatedFourByteStartCodesWithoutContaminatingPreviousNAL() {
    let bitstream = Data([
        0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x42, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x44, 0x01,
    ])

    let units = AnnexBBitstream.splitNALUnits(in: bitstream)

    #expect(units.map(\.hexString) == ["4001", "4201", "4401"])
}

@Test
func convertsRepeatedFourByteStartCodesToLengthPrefixedSample() {
    let bitstream = Data([
        0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x42, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x26, 0x01,
    ])

    let sample = AnnexBBitstream.lengthPrefixedSample(from: bitstream)

    #expect(sample.hexString == "000000024001000000024201000000022601")
}

@Test
func annexBHandlesEmptyUnitsAndTrailingStartCode() {
    let bytes = Data([0xFF, 0, 0, 1, 0, 0, 0, 1, 0x65, 0xAA, 0, 0, 1])
    #expect(AnnexBBitstream.splitNALUnits(in: bytes) == [Data([0x65, 0xAA])])
    #expect(AnnexBBitstream.lengthPrefixedSample(from: bytes) == Data([0, 0, 0, 2, 0x65, 0xAA]))
}

@Test
func annexBReadsDataWithNonzeroStartIndexAndKeepsEscapedBytes() {
    let storage = Data([0xFF, 0xFF, 0, 0, 1, 0x67, 0, 0, 3, 1, 0, 0, 0, 1, 0x65, 0xBB])
    let bytes = storage.dropFirst(2)
    #expect(bytes.startIndex == 2)
    #expect(AnnexBBitstream.splitNALUnits(in: bytes) == [Data([0x67, 0, 0, 3, 1]), Data([0x65, 0xBB])])
    #expect(AnnexBBitstream.codecParameterSets(from: bytes, codec: .h264) == [Data([0x67, 0, 0, 3, 1])])
    #expect(AnnexBBitstream.containsParameterSets(bytes, codec: .h264))
    #expect(!AnnexBBitstream.containsParameterSets(bytes, codec: .hevc))
    #expect(AnnexBBitstream.lengthPrefixedSample(from: bytes) == Data([0, 0, 0, 5, 0x67, 0, 0, 3, 1, 0, 0, 0, 2, 0x65, 0xBB]))
}

@Test
func annexBPreservesPayloadsWithoutNALUnits() {
    for bytes in [Data(), Data([0]), Data([0, 0]), Data([0, 0, 1]), Data([4, 5, 6, 7])] {
        #expect(AnnexBBitstream.splitNALUnits(in: bytes).isEmpty)
        #expect(AnnexBBitstream.lengthPrefixedSample(from: bytes) == bytes)
        #expect(!AnnexBBitstream.containsParameterSets(bytes, codec: .h264))
    }
}
