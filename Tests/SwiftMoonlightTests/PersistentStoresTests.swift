import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func fileIdentityStorePersistsGeneratedIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "identity.json")
    let store = FileIdentityStore(fileURL: fileURL, defaultDisplayName: "Test Client")

    let first = try await store.loadOrCreateIdentity()
    let second = try await store.loadOrCreateIdentity()

    #expect(first == second)
    #expect(first.displayName == "Test Client")
}

@Test
func keychainIdentityStorePersistsAndClearsGeneratedIdentity() async throws {
    let itemStore = InMemoryKeychainItemStore()
    let configuration = KeychainCredentialConfiguration(service: "test.swift-moonlight")
    let store = KeychainIdentityStore(
        itemStore: itemStore,
        configuration: configuration,
        defaultDisplayName: "Keychain Client"
    )

    let first = try await store.loadOrCreateIdentity()
    let second = try await store.loadOrCreateIdentity()
    try await store.clearIdentity()
    let third = try await store.loadOrCreateIdentity()

    #expect(first == second)
    #expect(first.displayName == "Keychain Client")
    #expect(third != first)
}

@Test
func keychainRSAPairingIdentityStorePersistsAndClearsMaterial() throws {
    let itemStore = InMemoryKeychainItemStore()
    let configuration = KeychainCredentialConfiguration(service: "test.swift-moonlight")
    let identity = ClientIdentity(identifier: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
    let store = KeychainRSAPairingIdentityStore(
        itemStore: itemStore,
        configuration: configuration
    )

    let first = try store.loadOrCreateIdentityMaterial(for: identity)
    let second = try store.loadOrCreateIdentityMaterial(for: identity)
    try store.clearIdentityMaterial(for: identity)
    let third = try store.loadOrCreateIdentityMaterial(for: identity)

    #expect(first == second)
    #expect(third != first)
}

@Test
func fileHostStoreRoundTripsHosts() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "hosts.json")
    let store = FileHostStore(fileURL: fileURL)
    let host = MoonlightHost(
        id: HostID(rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!),
        name: "Apollo",
        endpoint: .init(address: "10.0.0.2", port: 47989, securePort: 47984),
        kind: .apollo,
        pairingState: .paired,
        capabilities: .inferred(for: .apollo, codecSupportFlags: 1)
    )

    try await store.saveHosts([host])
    let loaded = try await store.loadHosts()

    #expect(loaded == [host])
}

@Test
func fileStoresHandlePathsWithSpaces() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "Application Support", directoryHint: .isDirectory)

    let hostFileURL = directory.appending(path: "hosts.json")
    let identityFileURL = directory.appending(path: "identity.json")
    let hostStore = FileHostStore(fileURL: hostFileURL)
    let identityStore = FileIdentityStore(fileURL: identityFileURL, defaultDisplayName: "Test Client")

    let host = MoonlightHost(
        id: HostID(rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!),
        name: "Sunshine",
        endpoint: .init(address: "10.0.0.3", port: 47989),
        kind: .sunshine,
        pairingState: .unpaired,
        capabilities: .default
    )

    try await hostStore.saveHosts([host])
    let loadedHosts = try await hostStore.loadHosts()
    let firstIdentity = try await identityStore.loadOrCreateIdentity()
    let secondIdentity = try await identityStore.loadOrCreateIdentity()

    #expect(loadedHosts == [host])
    #expect(firstIdentity == secondIdentity)
}

@Test
func productionClientFactoryBuildsDefaultRuntimeStack() throws {
    let hostStore = InMemoryHostStore()
    let identityStore = InMemoryIdentityStore()

    let configuration = ProductionClientFactory.configuration(
        hostStore: hostStore,
        identityStore: identityStore,
        enableDiscovery: false
    )

    #expect(configuration.hostDiscovery == nil)
    #expect(configuration.hostService != nil)
    #expect(configuration.sessionService != nil)
    #expect(configuration.pairingService != nil)
    #expect(configuration.sessionBootstrapService != nil)
}

private final class InMemoryKeychainItemStore: @unchecked Sendable, KeychainItemStore {
    private struct Key: Hashable {
        var account: String
        var service: String
        var accessGroup: String?
    }

    private let lock = NSLock()
    private var storage: [Key: Data] = [:]

    func load(account: String, service: String, accessGroup: String?) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Key(account: account, service: service, accessGroup: accessGroup)]
    }

    func save(_ data: Data, account: String, service: String, accessGroup: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[Key(account: account, service: service, accessGroup: accessGroup)] = data
    }

    func delete(account: String, service: String, accessGroup: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: Key(account: account, service: service, accessGroup: accessGroup))
    }
}
