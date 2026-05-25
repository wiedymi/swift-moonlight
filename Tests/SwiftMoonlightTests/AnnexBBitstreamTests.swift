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
