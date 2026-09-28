import Foundation

func fixtureData(named name: String) throws -> Data {
    let bundle = Bundle.module
    guard let url = bundle.url(forResource: name, withExtension: nil) else {
        struct MissingFixture: Error {}
        throw MissingFixture()
    }

    return try Data(contentsOf: url)
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    init?(hexString: String) {
        let normalized = hexString.replacingOccurrences(of: " ", with: "")
        guard normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)

        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }

        self.init(bytes)
    }
}
