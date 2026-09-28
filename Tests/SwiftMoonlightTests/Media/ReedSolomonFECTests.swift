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
