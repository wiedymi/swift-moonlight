import Foundation

enum ReedSolomonFECError: Error, Equatable {
    case invalidShardCounts
    case invalidShardSet
    case inconsistentShardSizes
    case unrecoverable
}

struct ReedSolomonFEC: Sendable {
    let dataShardCount: Int
    let parityShardCount: Int

    init(dataShardCount: Int, parityShardCount: Int) throws {
        guard dataShardCount > 0,
              parityShardCount > 0,
              dataShardCount + parityShardCount <= 255
        else {
            throw ReedSolomonFECError.invalidShardCounts
        }

        self.dataShardCount = dataShardCount
        self.parityShardCount = parityShardCount
    }

    func encodeParityShards(_ dataShards: [Data]) throws -> [Data] {
        guard dataShards.count == dataShardCount,
              let shardSize = dataShards.first?.count
        else {
            throw ReedSolomonFECError.invalidShardSet
        }
        guard dataShards.allSatisfy({ $0.count == shardSize }) else {
            throw ReedSolomonFECError.inconsistentShardSizes
        }

        let data = dataShards.map(Array.init)
        var parity = Array(
            repeating: Array(repeating: UInt8(0), count: shardSize),
            count: parityShardCount
        )

        for parityIndex in 0..<parityShardCount {
            for dataIndex in 0..<dataShardCount {
                let coefficient = parityCoefficient(parityIndex: parityIndex, dataIndex: dataIndex)
                xorMultiply(source: data[dataIndex], coefficient: coefficient, into: &parity[parityIndex])
            }
        }

        return parity.map { Data($0) }
    }

    func recoverDataShards(from shards: [Data?]) throws -> [Data] {
        guard shards.count == dataShardCount + parityShardCount else {
            throw ReedSolomonFECError.invalidShardSet
        }

        let knownSizes = shards.compactMap(\.?.count)
        guard let shardSize = knownSizes.first else {
            throw ReedSolomonFECError.invalidShardSet
        }
        guard knownSizes.allSatisfy({ $0 == shardSize }) else {
            throw ReedSolomonFECError.inconsistentShardSizes
        }

        var recovered = Array(shards.prefix(dataShardCount))
        let missingDataIndexes = recovered.indices.filter { recovered[$0] == nil }
        guard !missingDataIndexes.isEmpty else {
            return try recovered.map { shard in
                guard let shard else {
                    throw ReedSolomonFECError.invalidShardSet
                }
                return shard
            }
        }

        let availableParityIndexes = (0..<parityShardCount).filter { parityIndex in
            shards[dataShardCount + parityIndex] != nil
        }
        guard availableParityIndexes.count >= missingDataIndexes.count else {
            throw ReedSolomonFECError.unrecoverable
        }

        var matrix: [[UInt8]] = []
        var rhs: [[UInt8]] = []
        for parityIndex in availableParityIndexes.prefix(missingDataIndexes.count) {
            guard let parityShard = shards[dataShardCount + parityIndex] else {
                throw ReedSolomonFECError.invalidShardSet
            }

            var row = missingDataIndexes.map {
                parityCoefficient(parityIndex: parityIndex, dataIndex: $0)
            }
            var value = Array(parityShard)
            for dataIndex in 0..<dataShardCount {
                guard !missingDataIndexes.contains(dataIndex),
                      let shard = recovered[dataIndex]
                else {
                    continue
                }
                let coefficient = parityCoefficient(parityIndex: parityIndex, dataIndex: dataIndex)
                xorMultiply(source: Array(shard), coefficient: coefficient, into: &value)
            }

            matrix.append(row)
            rhs.append(value)
            row.removeAll(keepingCapacity: true)
        }

        let solved = try solve(matrix: matrix, rhs: rhs, shardSize: shardSize)
        for (solutionIndex, dataIndex) in missingDataIndexes.enumerated() {
            recovered[dataIndex] = Data(solved[solutionIndex])
        }

        return try recovered.map { shard in
            guard let shard else {
                throw ReedSolomonFECError.unrecoverable
            }
            return shard
        }
    }

    private func parityCoefficient(parityIndex: Int, dataIndex: Int) -> UInt8 {
        ReedSolomonGF256.inverse(UInt8((parityShardCount + dataIndex) ^ parityIndex))
    }

    private func solve(matrix: [[UInt8]], rhs: [[UInt8]], shardSize: Int) throws -> [[UInt8]] {
        let width = matrix.count
        guard width > 0,
              matrix.allSatisfy({ $0.count == width }),
              rhs.count == width,
              rhs.allSatisfy({ $0.count == shardSize })
        else {
            throw ReedSolomonFECError.invalidShardSet
        }

        var matrix = matrix
        var rhs = rhs

        for pivotIndex in 0..<width {
            guard let pivotRow = (pivotIndex..<width).first(where: {
                matrix[$0][pivotIndex] != 0
            }) else {
                throw ReedSolomonFECError.unrecoverable
            }
            if pivotRow != pivotIndex {
                matrix.swapAt(pivotIndex, pivotRow)
                rhs.swapAt(pivotIndex, pivotRow)
            }

            let inversePivot = ReedSolomonGF256.inverse(matrix[pivotIndex][pivotIndex])
            for column in pivotIndex..<width {
                matrix[pivotIndex][column] = ReedSolomonGF256.multiply(matrix[pivotIndex][column], inversePivot)
            }
            multiply(row: &rhs[pivotIndex], by: inversePivot)

            for rowIndex in 0..<width where rowIndex != pivotIndex {
                let factor = matrix[rowIndex][pivotIndex]
                guard factor != 0 else {
                    continue
                }

                for column in pivotIndex..<width {
                    matrix[rowIndex][column] ^= ReedSolomonGF256.multiply(factor, matrix[pivotIndex][column])
                }
                xorMultiply(source: rhs[pivotIndex], coefficient: factor, into: &rhs[rowIndex])
            }
        }

        return rhs
    }

    private func xorMultiply(source: [UInt8], coefficient: UInt8, into destination: inout [UInt8]) {
        guard coefficient != 0 else {
            return
        }

        if coefficient == 1 {
            for index in source.indices {
                destination[index] ^= source[index]
            }
            return
        }

        for index in source.indices {
            destination[index] ^= ReedSolomonGF256.multiply(source[index], coefficient)
        }
    }

    private func multiply(row: inout [UInt8], by coefficient: UInt8) {
        guard coefficient != 1 else {
            return
        }

        for index in row.indices {
            row[index] = ReedSolomonGF256.multiply(row[index], coefficient)
        }
    }
}

private enum ReedSolomonGF256 {
    private static let primitivePolynomial: UInt16 = 0x11D

    static func multiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        guard lhs != 0, rhs != 0 else {
            return 0
        }

        var left = UInt16(lhs)
        var right = UInt16(rhs)
        var result: UInt16 = 0

        while right != 0 {
            if right & 1 != 0 {
                result ^= left
            }
            right >>= 1
            left <<= 1
            if left & 0x100 != 0 {
                left ^= primitivePolynomial
            }
        }

        return UInt8(truncatingIfNeeded: result)
    }

    static func inverse(_ value: UInt8) -> UInt8 {
        precondition(value != 0, "Zero has no multiplicative inverse in GF(256)")
        return power(value, 254)
    }

    private static func power(_ value: UInt8, _ exponent: Int) -> UInt8 {
        var result: UInt8 = 1
        var base = value
        var exponent = exponent

        while exponent > 0 {
            if exponent & 1 == 1 {
                result = multiply(result, base)
            }
            exponent >>= 1
            if exponent > 0 {
                base = multiply(base, base)
            }
        }

        return result
    }
}
