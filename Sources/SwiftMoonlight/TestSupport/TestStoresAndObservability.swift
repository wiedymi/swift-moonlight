import Foundation

public actor InMemoryHostStore: HostStore {
    private var hosts: [MoonlightHost]

    public init(hosts: [MoonlightHost] = []) {
        self.hosts = hosts
    }

    public func loadHosts() async throws -> [MoonlightHost] {
        hosts
    }

    public func saveHosts(_ hosts: [MoonlightHost]) async throws {
        self.hosts = hosts
    }
}

public actor FixtureHostDiscovery: HostDiscovery {
    private let discoveredHosts: [DiscoveredHost]

    public init(discoveredHosts: [DiscoveredHost]) {
        self.discoveredHosts = discoveredHosts
    }

    public func discover(timeout: Duration) async throws -> [DiscoveredHost] {
        _ = timeout
        return discoveredHosts
    }
}

public actor InMemoryIdentityStore: IdentityStore {
    private var identity: ClientIdentity?

    public init(identity: ClientIdentity? = nil) {
        self.identity = identity
    }

    public func loadOrCreateIdentity() async throws -> ClientIdentity {
        if let identity {
            return identity
        }

        let newIdentity = ClientIdentity()
        identity = newIdentity
        return newIdentity
    }

    public func clearIdentity() async throws {
        identity = nil
    }
}

public struct TestLogger: MoonlightLogger {
    public init() {}

    public func debug(_ message: String) { _ = message }
    public func info(_ message: String) { _ = message }
    public func warning(_ message: String) { _ = message }
    public func error(_ message: String) { _ = message }
}

public actor RecordingMetricsSink: MetricsSink {
    private var snapshots: [SessionMetricsSnapshot]

    public init(snapshots: [SessionMetricsSnapshot] = []) {
        self.snapshots = snapshots
    }

    public func record(_ snapshot: SessionMetricsSnapshot) async {
        snapshots.append(snapshot)
    }

    public func recordedSnapshots() -> [SessionMetricsSnapshot] {
        snapshots
    }
}
