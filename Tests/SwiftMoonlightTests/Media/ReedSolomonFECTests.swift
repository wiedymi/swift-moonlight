import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func reedSolomonFECRecoversSingleMissingDataShard() throws {
    let fec = try ReedSolomonFEC(dataShardCount: 3, parityShardCount: 2)
    let data = [
        Data([0x01, 0x02, 0x03, 0x04]),
        Data([0x10, 0x20, 0x30, 0x40]),
        Data([0xAA, 0xBB, 0xCC, 0xDD]),
    ]
    let parity = try fec.encodeParityShards(data)

    let recovered = try fec.recoverDataShards(from: [
        data[0],
        nil,
        data[2],
        parity[0],
        nil,
    ])

    #expect(recovered == data)
}

@Test
func reedSolomonFECRecoversMultipleMissingDataShards() throws {
    let fec = try ReedSolomonFEC(dataShardCount: 4, parityShardCount: 3)
    let data = [
        Data([0x00, 0x01, 0x02, 0x03, 0x04]),
        Data([0x10, 0x11, 0x12, 0x13, 0x14]),
        Data([0x20, 0x21, 0x22, 0x23, 0x24]),
        Data([0x30, 0x31, 0x32, 0x33, 0x34]),
    ]
    let parity = try fec.encodeParityShards(data)

    let recovered = try fec.recoverDataShards(from: [
        nil,
        data[1],
        nil,
        data[3],
        parity[0],
        nil,
        parity[2],
    ])

    #expect(recovered == data)
}

@Test
func reedSolomonFECRejectsUnrecoverableShardSet() throws {
    let fec = try ReedSolomonFEC(dataShardCount: 3, parityShardCount: 1)
    let data = [
        Data([0x01, 0x02]),
        Data([0x03, 0x04]),
        Data([0x05, 0x06]),
    ]
    let parity = try fec.encodeParityShards(data)

    #expect(throws: ReedSolomonFECError.unrecoverable) {
        _ = try fec.recoverDataShards(from: [
            nil,
            data[1],
            nil,
            parity[0],
        ])
    }
}

@Test
func reedSolomonFECRejectsInconsistentShardSizes() throws {
    let fec = try ReedSolomonFEC(dataShardCount: 2, parityShardCount: 1)

    #expect(throws: ReedSolomonFECError.inconsistentShardSizes) {
        _ = try fec.recoverDataShards(from: [
            Data([0x01]),
            nil,
            Data([0x02, 0x03]),
        ])
    }
}

@Test
func reedSolomonProductsMatchPolynomialArithmeticForEveryBytePair() {
    for lhs in 0..<256 {
        for rhs in 0..<256 {
            var left = lhs
            var right = rhs
            var result = 0
            for _ in 0..<8 {
                if right & 1 != 0 { result ^= left }
                right >>= 1
                left <<= 1
                if left & 0x100 != 0 { left ^= 0x11D }
            }
            #expect(ReedSolomonGF256.multiply(UInt8(lhs), UInt8(rhs)) == UInt8(result))
        }
    }
}

@Test
func reedSolomonRejectsHugeCountsWithoutOverflow() {
    #expect(throws: ReedSolomonFECError.invalidShardCounts) {
        _ = try ReedSolomonFEC(dataShardCount: Int.max, parityShardCount: Int.max)
    }
}

@Test
func reedSolomonRecoversLargeShardsAtDifferentMissingPositions() throws {
    let fec = try ReedSolomonFEC(dataShardCount: 32, parityShardCount: 8)
    let data = (0..<32).map { row in Data((0..<1400).map { UInt8(truncatingIfNeeded: row * 31 + $0 * 17) }) }
    let parity = try fec.encodeParityShards(data)
    for missing in [[0], [31], [0, 5, 17], Array(0..<8)] {
        var shards = (data + parity).map(Optional.some)
        for index in missing { shards[index] = nil }
        #expect(try fec.recoverDataShards(from: shards) == data)
    }
    let emptyData = [Data(), Data()]
    let emptyCodec = try ReedSolomonFEC(dataShardCount: 2, parityShardCount: 1)
    let emptyParity = try emptyCodec.encodeParityShards(emptyData)
    #expect(try emptyCodec.recoverDataShards(from: [nil, Data(), emptyParity[0]]) == emptyData)
}
