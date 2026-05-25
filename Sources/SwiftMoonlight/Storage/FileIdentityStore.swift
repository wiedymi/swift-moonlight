import Foundation

public actor FileIdentityStore: IdentityStore {
    private let fileURL: URL
    private let defaultDisplayName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL, defaultDisplayName: String = "swift-moonlight") {
        self.fileURL = fileURL
        self.defaultDisplayName = defaultDisplayName
    }

    public func loadOrCreateIdentity() async throws -> ClientIdentity {
        if FileManager.default.fileExists(atPath: fileURL.fileSystemPath) {
            let data = try Data(contentsOf: fileURL)
            let persisted = try decoder.decode(PersistedClientIdentity.self, from: data)
            return persisted.identity
        }

        let identity = ClientIdentity(displayName: defaultDisplayName)
        let data = try encoder.encode(PersistedClientIdentity(identity: identity))
        try writeAtomically(data, to: fileURL)
        return identity
    }

    public func clearIdentity() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.fileSystemPath) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

private extension URL {
    var fileSystemPath: String {
        path(percentEncoded: false)
    }
}

private struct PersistedClientIdentity: Codable {
    let identifier: UUID
    let displayName: String

    init(identity: ClientIdentity) {
        identifier = identity.identifier
        displayName = identity.displayName
    }

    var identity: ClientIdentity {
        ClientIdentity(identifier: identifier, displayName: displayName)
    }
}
