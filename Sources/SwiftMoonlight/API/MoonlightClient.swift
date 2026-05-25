import Foundation

public struct MoonlightClientConfiguration: Sendable {
    public var hostStore: any HostStore
    public var hostDiscovery: (any HostDiscovery)?
    public var identityStore: any IdentityStore
    public var clock: any Clock
    public var logger: any MoonlightLogger
    public var metricsSink: any MetricsSink
    public var hostService: (any HostService)?
    public var sessionService: (any SessionService)?
    public var pairingService: (any PairingClientService)?
    public var sessionBootstrapService: (any SessionBootstrapService)?

    public init(
        hostStore: any HostStore,
        hostDiscovery: (any HostDiscovery)? = nil,
        identityStore: any IdentityStore,
        clock: any Clock,
        logger: any MoonlightLogger,
        metricsSink: any MetricsSink,
        hostService: (any HostService)?,
        sessionService: (any SessionService)? = nil,
        pairingService: (any PairingClientService)? = nil,
        sessionBootstrapService: (any SessionBootstrapService)? = nil
    ) {
        self.hostStore = hostStore
        self.hostDiscovery = hostDiscovery
        self.identityStore = identityStore
        self.clock = clock
        self.logger = logger
        self.metricsSink = metricsSink
        self.hostService = hostService
        self.sessionService = sessionService
        self.pairingService = pairingService
        self.sessionBootstrapService = sessionBootstrapService
    }
}

public struct SessionRestartOptions: Equatable, Sendable {
    public var stopExistingRuntime: Bool
    public var cancelCurrentAppBeforeRelaunch: Bool
    public var runtimeConfiguration: StreamRuntimeConfiguration

    public init(
        stopExistingRuntime: Bool = true,
        cancelCurrentAppBeforeRelaunch: Bool = true,
        runtimeConfiguration: StreamRuntimeConfiguration = .init()
    ) {
        self.stopExistingRuntime = stopExistingRuntime
        self.cancelCurrentAppBeforeRelaunch = cancelCurrentAppBeforeRelaunch
        self.runtimeConfiguration = runtimeConfiguration
    }
}

public struct RestartedSession: Sendable {
    public var session: MoonlightSession
    public var preparedRuntime: PreparedSessionRuntime

    public init(session: MoonlightSession, preparedRuntime: PreparedSessionRuntime) {
        self.session = session
        self.preparedRuntime = preparedRuntime
    }
}

public actor MoonlightClient {
    private let configuration: MoonlightClientConfiguration

    public init(configuration: MoonlightClientConfiguration) {
        self.configuration = configuration
    }

    public func discoverHosts() async throws -> [MoonlightHost] {
        let storedHosts = try await configuration.hostStore.loadHosts()
        var hosts = canonicalizedHosts(storedHosts)
        var shouldSaveHosts = hosts != storedHosts
        guard let hostDiscovery = configuration.hostDiscovery else {
            if shouldSaveHosts {
                try await configuration.hostStore.saveHosts(hosts)
            }
            return hosts
        }

        let discoveredHosts = try await hostDiscovery.discover(timeout: .seconds(1))
        for discovered in discoveredHosts {
            let alreadyKnown = hosts.contains {
                $0.endpoint.address == discovered.endpoint.address &&
                $0.endpoint.port == discovered.endpoint.port
            }
            guard !alreadyKnown else {
                continue
            }
            shouldSaveHosts = true

            hosts.append(MoonlightHost(
                id: HostID(),
                name: discovered.name,
                endpoint: discovered.endpoint,
                kind: .unknown,
                pairingState: .unpaired,
                capabilities: .default
            ))
        }

        if shouldSaveHosts {
            try await configuration.hostStore.saveHosts(hosts)
        }
        return hosts
    }

    public func addHost(_ endpoint: HostEndpoint) async throws -> MoonlightHost {
        let storedHosts = try await configuration.hostStore.loadHosts()
        var hosts = canonicalizedHosts(storedHosts)
        if hosts != storedHosts {
            try await configuration.hostStore.saveHosts(hosts)
        }
        if let existing = hosts.first(where: { sameEndpoint($0.endpoint, endpoint) }) {
            return existing
        }

        let host = MoonlightHost(
            id: HostID(),
            name: endpoint.address,
            endpoint: endpoint,
            kind: .unknown,
            pairingState: .unpaired,
            capabilities: .default
        )
        hosts.append(host)
        try await configuration.hostStore.saveHosts(hosts)
        return host
    }

    public func updateHostEndpoint(hostID: HostID, endpoint: HostEndpoint) async throws -> MoonlightHost {
        let storedHosts = try await configuration.hostStore.loadHosts()
        var hosts = canonicalizedHosts(storedHosts)
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
            throw MoonlightError(.hostNotFound, message: "Unknown host \(hostID.rawValue)")
        }

        var updatedEndpoint = endpoint
        updatedEndpoint.securePort = endpoint.securePort ?? hosts[index].endpoint.securePort
        hosts[index].endpoint = updatedEndpoint

        let updatedID = hosts[index].id
        hosts = canonicalizedHosts(hosts)
        try await configuration.hostStore.saveHosts(hosts)

        guard let updated = hosts.first(where: { $0.id == updatedID })
            ?? hosts.first(where: { sameEndpoint($0.endpoint, updatedEndpoint) })
        else {
            throw MoonlightError(.hostNotFound, message: "Updated host \(hostID.rawValue) was not persisted")
        }
        return updated
    }

    public func refreshHost(_ hostID: HostID) async throws -> MoonlightHost {
        let storedHosts = try await configuration.hostStore.loadHosts()
        var hosts = canonicalizedHosts(storedHosts)
        if hosts != storedHosts {
            try await configuration.hostStore.saveHosts(hosts)
        }
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
            throw MoonlightError(.hostNotFound, message: "Unknown host \(hostID.rawValue)")
        }

        guard let hostService = configuration.hostService else {
            return hosts[index]
        }

        let rawServerInfo = try await hostService.fetchServerInfo(for: hosts[index])
        let serverInfo = try HostInfoParser().parseServerInfo(rawServerInfo)
        hosts[index].endpoint.securePort = serverInfo.httpsPort ?? hosts[index].endpoint.securePort
        hosts[index].pairingState = mergePairingState(
            stored: hosts[index].pairingState,
            refreshed: serverInfo.pairingState
        )
        hosts[index].kind = inferHostKind(from: serverInfo)
        hosts[index].compatibilityProfile = .for(hosts[index].kind)
        hosts[index].capabilities = .inferred(
            for: hosts[index].kind,
            codecSupportFlags: serverInfo.codecSupportFlags
        )
        try await configuration.hostStore.saveHosts(hosts)
        return hosts[index]
    }

    public func refreshHost(_ host: MoonlightHost) async throws -> MoonlightHost {
        let resolvedHost = try await canonicalHost(for: host)
        return try await refreshHost(resolvedHost.id)
    }

    public func pair(hostID: HostID, pin: String) async throws -> PairingResult {
        try await pair(hostID: hostID, auth: .pin(pin))
    }

    public func pair(hostID: HostID, auth: PairingAuth) async throws -> PairingResult {
        guard !auth.pin.isEmpty else {
            throw MoonlightError(.pairingRejected, message: "PIN must not be empty")
        }
        if case .otp(_, let passphrase) = auth, passphrase.isEmpty {
            throw MoonlightError(.pairingRejected, message: "OTP passphrase must not be empty")
        }

        let identity = try await configuration.identityStore.loadOrCreateIdentity()
        var hosts = try await configuration.hostStore.loadHosts()
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
            throw MoonlightError(.hostNotFound, message: "Unknown host \(hostID.rawValue)")
        }

        if let pairingService = configuration.pairingService {
            let result = try await pairingService.pair(host: hosts[index], auth: auth, identity: identity)
            hosts[index].pairingState = result.state
            if hosts[index].kind == .unknown {
                hosts[index].kind = .sunshine
            }
            try await configuration.hostStore.saveHosts(hosts)
            return result
        }

        hosts[index].pairingState = .paired
        if hosts[index].kind == .unknown {
            hosts[index].kind = .sunshine
        }
        try await configuration.hostStore.saveHosts(hosts)

        return PairingResult(hostID: hostID, state: .paired)
    }

    public func pair(host: MoonlightHost, auth: PairingAuth) async throws -> PairingResult {
        let resolvedHost = try await canonicalHost(for: host)
        return try await pair(hostID: resolvedHost.id, auth: auth)
    }

    public func unpair(hostID: HostID) async throws {
        let identity = try await configuration.identityStore.loadOrCreateIdentity()
        var hosts = try await configuration.hostStore.loadHosts()
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
            throw MoonlightError(.hostNotFound, message: "Unknown host \(hostID.rawValue)")
        }

        if let pairingService = configuration.pairingService {
            try await pairingService.unpair(host: hosts[index], identity: identity)
        }

        hosts[index].pairingState = .unpaired
        try await configuration.hostStore.saveHosts(hosts)
    }

    public func unpair(host: MoonlightHost) async throws {
        let resolvedHost = try await canonicalHost(for: host)
        try await unpair(hostID: resolvedHost.id)
    }

    public func fetchApps(hostID: HostID) async throws -> [RemoteApp] {
        let host = try await refreshHost(hostID)
        guard host.pairingState.isPaired else {
            throw MoonlightError(.hostNotPaired, message: "Host must be paired before fetching apps")
        }

        guard let hostService = configuration.hostService else {
            return [RemoteApp(id: "desktop", name: "Desktop")]
        }

        let rawAppList = try await hostService.fetchAppList(for: host)
        return try AppListParser().parseAppList(rawAppList)
    }

    public func fetchApps(host: MoonlightHost) async throws -> [RemoteApp] {
        let resolvedHost = try await canonicalHost(for: host)
        return try await fetchApps(hostID: resolvedHost.id)
    }

    public func openSession(
        hostID: HostID,
        appID: RemoteApp.ID,
        configuration sessionConfiguration: StreamConfiguration
    ) async throws -> MoonlightSession {
        try sessionConfiguration.validate()
        let startedAt = self.configuration.clock.now()
        let host = try await refreshHost(hostID)
        try sessionConfiguration.validate(against: host)
        guard host.pairingState.isPaired else {
            throw MoonlightError(.hostNotPaired, message: "Host must be paired before opening a session")
        }

        let identity = try await configuration.identityStore.loadOrCreateIdentity()
        let bootstrapped: BootstrappedSession
        if let bootstrap = configuration.sessionBootstrapService {
            bootstrapped = try await bootstrap.openSession(
                host: host,
                appID: appID,
                configuration: sessionConfiguration,
                identity: identity
            )
        } else {
            let negotiated = try await configuration.sessionService?.launchSession(
                for: host,
                appID: appID,
                configuration: sessionConfiguration,
                identity: identity
            ) ?? NegotiatedSession(hostID: host.id, appID: appID, rtspSessionURL: "rtsp://\(host.endpoint.address):47998")
            bootstrapped = BootstrappedSession(negotiatedSession: negotiated)
        }

        let session = MoonlightSession(
            negotiatedSession: bootstrapped.negotiatedSession,
            primedSockets: bootstrapped.primedSockets,
            clock: self.configuration.clock
        )
        let finishedAt = self.configuration.clock.now()
        let durationMs = max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000))
        await session.updateRuntimeMetrics(sessionOpenDurationMs: durationMs)
        await session.attachMetricsSink(self.configuration.metricsSink)
        self.configuration.logger.info(
            "Opening session for host \(host.id.rawValue) at \(sessionConfiguration.frameRate) FPS"
        )
        return session
    }

    public func openSession(
        host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration sessionConfiguration: StreamConfiguration
    ) async throws -> MoonlightSession {
        let resolvedHost = try await canonicalHost(for: host)
        return try await openSession(hostID: resolvedHost.id, appID: appID, configuration: sessionConfiguration)
    }

    public func prepareRuntime(
        for session: MoonlightSession,
        hostID: HostID,
        configuration runtimeConfiguration: StreamRuntimeConfiguration = .init()
    ) async throws -> PreparedSessionRuntime {
        // Use the stored host directly instead of refreshing again.
        // The host was already refreshed during openSession(). An extra
        // refresh here delays the receive loop start, causing the initial
        // keyframe to overflow the UDP receive buffer.
        let hosts = try await configuration.hostStore.loadHosts()
        guard let host = hosts.first(where: { $0.id == hostID }) else {
            throw MoonlightError(.hostNotFound, message: "Unknown host \(hostID.rawValue)")
        }
        return try await SessionRuntimeFactory(logger: configuration.logger).makeRuntime(
            host: host,
            session: session,
            configuration: runtimeConfiguration
        )
    }

    public func prepareRuntime(
        for session: MoonlightSession,
        host: MoonlightHost,
        configuration runtimeConfiguration: StreamRuntimeConfiguration = .init()
    ) async throws -> PreparedSessionRuntime {
        let resolvedHost = try await canonicalHost(for: host)
        return try await prepareRuntime(for: session, hostID: resolvedHost.id, configuration: runtimeConfiguration)
    }

    public func restartSession(
        hostID: HostID,
        appID: RemoteApp.ID,
        configuration sessionConfiguration: StreamConfiguration,
        previousRuntime: PreparedSessionRuntime?,
        options: SessionRestartOptions = .init()
    ) async throws -> RestartedSession {
        try sessionConfiguration.validate()
        let host = try await refreshHost(hostID)
        try sessionConfiguration.validate(against: host)
        guard host.pairingState.isPaired else {
            throw MoonlightError(.hostNotPaired, message: "Host must be paired before restarting a session")
        }

        if options.stopExistingRuntime {
            await previousRuntime?.stop()
        }

        if options.cancelCurrentAppBeforeRelaunch, let hostService = configuration.hostService {
            try await hostService.cancelCurrentApp(for: host)
        }

        let session = try await openSession(
            hostID: hostID,
            appID: appID,
            configuration: sessionConfiguration
        )
        let preparedRuntime = try await prepareRuntime(
            for: session,
            hostID: hostID,
            configuration: options.runtimeConfiguration
        )
        return RestartedSession(session: session, preparedRuntime: preparedRuntime)
    }

    public func restartSession(
        host: MoonlightHost,
        appID: RemoteApp.ID,
        configuration sessionConfiguration: StreamConfiguration,
        previousRuntime: PreparedSessionRuntime?,
        options: SessionRestartOptions = .init()
    ) async throws -> RestartedSession {
        let resolvedHost = try await canonicalHost(for: host)
        return try await restartSession(
            hostID: resolvedHost.id,
            appID: appID,
            configuration: sessionConfiguration,
            previousRuntime: previousRuntime,
            options: options
        )
    }

    public func cancelCurrentApp(hostID: HostID) async throws {
        let host = try await refreshHost(hostID)
        guard let hostService = configuration.hostService else {
            return
        }
        try await hostService.cancelCurrentApp(for: host)
    }

    public func cancelCurrentApp(host: MoonlightHost) async throws {
        let resolvedHost = try await canonicalHost(for: host)
        try await cancelCurrentApp(hostID: resolvedHost.id)
    }

    private func inferHostKind(from serverInfo: ServerInfo) -> HostKind {
        let appVersion = serverInfo.appVersion?.lowercased() ?? ""
        if appVersion.contains("apollo") {
            return .apollo
        }
        if serverInfo.permissionMask != nil {
            return .apollo
        }
        if appVersion.contains("sunshine") {
            return .sunshine
        }
        if serverInfo.gfeVersion != nil || serverInfo.codecSupportFlags != 0 {
            return .sunshine
        }
        return .unknown
    }

    private func mergePairingState(stored: PairingState, refreshed: PairingState) -> PairingState {
        switch (stored, refreshed) {
        case (.paired, .unpaired):
            return .paired
        case (_, .unknown):
            return stored
        default:
            return refreshed
        }
    }

    private func canonicalHost(for host: MoonlightHost) async throws -> MoonlightHost {
        let storedHosts = try await configuration.hostStore.loadHosts()
        var hosts = canonicalizedHosts(storedHosts)
        if hosts != storedHosts {
            try await configuration.hostStore.saveHosts(hosts)
        }

        if let existing = hosts.first(where: { $0.id == host.id }) {
            return existing
        }

        if let index = hosts.firstIndex(where: { sameEndpoint($0.endpoint, host.endpoint) }) {
            if hosts[index] != host {
                hosts[index] = mergedHost(hosts[index], host)
                try await configuration.hostStore.saveHosts(hosts)
            }
            return hosts[index]
        }

        hosts.append(host)
        try await configuration.hostStore.saveHosts(hosts)
        return host
    }

    private func canonicalizedHosts(_ hosts: [MoonlightHost]) -> [MoonlightHost] {
        var canonical: [MoonlightHost] = []
        canonical.reserveCapacity(hosts.count)

        for host in hosts {
            if let index = canonical.firstIndex(where: { sameEndpoint($0.endpoint, host.endpoint) }) {
                canonical[index] = mergedHost(canonical[index], host)
            } else {
                canonical.append(host)
            }
        }

        return canonical
    }

    private func sameEndpoint(_ lhs: HostEndpoint, _ rhs: HostEndpoint) -> Bool {
        lhs.address.caseInsensitiveCompare(rhs.address) == .orderedSame && lhs.port == rhs.port
    }

    private func mergedHost(_ current: MoonlightHost, _ candidate: MoonlightHost) -> MoonlightHost {
        var base = shouldPrefer(candidate, over: current) ? candidate : current
        let other = base.id == current.id ? candidate : current
        let kind = base.kind == .unknown ? other.kind : base.kind
        let quirks = HostQuirkSet(
            base.compatibilityProfile.quirks.values
                .union(other.compatibilityProfile.quirks.values)
                .union(HostQuirkSet.for(kind).values)
        )

        base.endpoint.securePort = base.endpoint.securePort ?? other.endpoint.securePort
        if base.name == base.endpoint.address, other.name != other.endpoint.address {
            base.name = other.name
        }
        base.kind = kind
        base.pairingState = mergedPairingState(base.pairingState, other.pairingState)
        base.capabilities = mergedCapabilities(base.capabilities, other.capabilities)
        base.compatibilityProfile = HostCompatibilityProfile(kind: kind, quirks: quirks)
        return base
    }

    private func shouldPrefer(_ candidate: MoonlightHost, over current: MoonlightHost) -> Bool {
        if candidate.pairingState == .paired, current.pairingState != .paired {
            return true
        }
        if current.pairingState == .paired, candidate.pairingState != .paired {
            return false
        }
        if candidate.kind != .unknown, current.kind == .unknown {
            return true
        }
        if current.kind != .unknown, candidate.kind == .unknown {
            return false
        }
        if candidate.endpoint.securePort != nil, current.endpoint.securePort == nil {
            return true
        }
        return false
    }

    private func mergedPairingState(_ lhs: PairingState, _ rhs: PairingState) -> PairingState {
        if lhs == .paired || rhs == .paired {
            return .paired
        }
        if lhs == .unknown || rhs == .unknown {
            return .unknown
        }
        return .unpaired
    }

    private func mergedCapabilities(_ lhs: HostCapabilities, _ rhs: HostCapabilities) -> HostCapabilities {
        var codecs = lhs.supportedVideoCodecs
        for codec in rhs.supportedVideoCodecs where !codecs.contains(codec) {
            codecs.append(codec)
        }
        return HostCapabilities(
            supportsControllerInput: lhs.supportsControllerInput || rhs.supportsControllerInput,
            supportsTouchInput: lhs.supportsTouchInput || rhs.supportsTouchInput,
            supportsHardwareDecode: lhs.supportsHardwareDecode || rhs.supportsHardwareDecode,
            supportsSoftwareDecodeFallback: lhs.supportsSoftwareDecodeFallback || rhs.supportsSoftwareDecodeFallback,
            supportsInputOnlySession: lhs.supportsInputOnlySession || rhs.supportsInputOnlySession,
            supportsOTPAuth: lhs.supportsOTPAuth || rhs.supportsOTPAuth,
            requiresPerClientAuthorization: lhs.requiresPerClientAuthorization || rhs.requiresPerClientAuthorization,
            supportedVideoCodecs: codecs,
            supportsHDR: lhs.supportsHDR || rhs.supportsHDR
        )
    }
}
