import Foundation
#if canImport(Network)
import Network

private final class DiscoveryAccumulator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "swift-moonlight.bonjour-discovery")
    private var discovered: [String: DiscoveredHost] = [:]

    func store(_ host: DiscoveredHost) {
        queue.sync {
            discovered["\(host.name)|\(host.endpoint.address)"] = host
        }
    }

    func snapshot() -> [DiscoveredHost] {
        queue.sync { Array(discovered.values) }
    }
}

public actor BonjourHostDiscovery: HostDiscovery {
    public let serviceType: String

    public init(serviceType: String = "_nvstream._tcp") {
        self.serviceType = serviceType
    }

    public func discover(timeout: Duration) async throws -> [DiscoveredHost] {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )

        let accumulator = DiscoveryAccumulator()
        let started = AsyncStream<Void> { continuation in
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(())
                    continuation.finish()
                case .failed:
                    continuation.finish()
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else {
                    continue
                }
                let hostAddress = "\(name).local"
                accumulator.store(.init(
                    name: name,
                    endpoint: HostEndpoint(address: hostAddress, port: 47989)
                ))
            }
        }

        browser.start(queue: .global(qos: .userInitiated))
        defer {
            browser.cancel()
        }

        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        try await Task.sleep(for: timeout)
        return accumulator.snapshot().sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.endpoint.address < rhs.endpoint.address
            }
            return lhs.name < rhs.name
        }
    }
}
#endif
