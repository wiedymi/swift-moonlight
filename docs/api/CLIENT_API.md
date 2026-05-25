# Client API

This document defines the top-level developer-facing API.

## Goals

- simple enough for app teams to adopt quickly
- powerful enough to expose session metrics and advanced configuration
- no packet-level knowledge required for normal use

## Primary Types

```swift
public struct MoonlightClientConfiguration: Sendable {
    public var hostStore: any HostStore
    public var hostDiscovery: (any HostDiscovery)?
    public var identityStore: any IdentityStore
    public var clock: any Clock
    public var logger: any MoonlightLogger
    public var metricsSink: any MetricsSink
}

public actor MoonlightClient {
    public init(configuration: MoonlightClientConfiguration)

    public func discoverHosts() async throws -> [MoonlightHost]
    public func addHost(_ endpoint: HostEndpoint) async throws -> MoonlightHost
    public func updateHostEndpoint(hostID: HostID, endpoint: HostEndpoint) async throws -> MoonlightHost
    public func refreshHost(_ hostID: HostID) async throws -> MoonlightHost
    public func pair(hostID: HostID, pin: String) async throws -> PairingResult
    public func unpair(hostID: HostID) async throws
    public func fetchApps(hostID: HostID) async throws -> [RemoteApp]
    public func openSession(
        hostID: HostID,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration
    ) async throws -> MoonlightSession
    public func restartSession(
        hostID: HostID,
        appID: RemoteApp.ID,
        configuration: StreamConfiguration,
        previousRuntime: PreparedSessionRuntime?,
        options: SessionRestartOptions
    ) async throws -> RestartedSession
}
```

## Usage

```swift
let configuration = try ProductionClientFactory.configuration(
    storageDirectory: appSupportDirectory
)

let client = MoonlightClient(configuration: configuration)

let hosts = try await client.discoverHosts()
let host = try await client.refreshHost(hosts[0].id)

if !host.pairingState.isPaired {
    try await client.pair(hostID: host.id, pin: "1234")
}

let apps = try await client.fetchApps(hostID: host.id)
let session = try await client.openSession(
    hostID: host.id,
    appID: apps[0].id,
    configuration: .default1080p60
)
```

For app-driven relaunches, such as changing the stream-window resolution for an Apollo virtual display, use the restart helper instead of hand-rolling stop/cancel/relaunch ordering:

```swift
let restarted = try await client.restartSession(
    hostID: host.id,
    appID: app.id,
    configuration: resizedConfiguration,
    previousRuntime: preparedRuntime,
    options: .init(cancelCurrentAppBeforeRelaunch: true)
)

try await AppleMediaComponents.attachRecommendedPlaybackComponents(
    to: restarted.session,
    device: device,
    layer: metalLayer,
    presentationConfiguration: MetalPresentationConfiguration(contentMode: .stretch)
)
await restarted.preparedRuntime.runtime.start()
```

For shipping Apple apps, use Keychain-backed credentials while keeping host metadata in the app support directory:

```swift
let configuration = try ProductionClientFactory.configuration(
    storageDirectory: appSupportDirectory,
    credentialStorage: .keychain(.init(service: "com.example.myapp.moonlight"))
)
```

## DX Constraints

- the top-level API must be `async` and actor-safe
- the top-level API must not expose transport internals
- advanced behavior should be opt-in via configuration types, not required ceremony

Current implementation note:
- when `hostDiscovery` is configured, `discoverHosts()` merges `_nvstream._tcp` discovery results into the persisted host store before returning hosts
- `discoverHosts()` and `addHost(_:)` canonicalize stored hosts by endpoint, preserving paired or richer host metadata instead of accumulating duplicate unpaired rows for the same host
- `updateHostEndpoint(hostID:endpoint:)` lets apps replace a stale hostname with a manual IP/port while preserving pairing state, compatibility metadata, capabilities, and an existing secure port when the replacement endpoint does not specify one
- `ProductionClientFactory.configuration(...)` now wires the current production default stack:
  - `FileHostStore`
  - `FileIdentityStore` or opt-in `KeychainIdentityStore`
  - `BonjourHostDiscovery`
  - `HTTPHostService`
  - `CryptoPairingClientService`
  - `LaunchSessionService`
  - `SessionBootstrap`
- `ProductionClientFactory.configuration(..., credentialStorage: .keychain(...))` stores client identity and RSA pairing material in Apple Keychain-backed generic-password items
- `openSession(...)` now forwards the session metric stream into the configured `MetricsSink`
- `restartSession(...)` validates the replacement `StreamConfiguration` before stopping the old runtime or cancelling the host app, then returns a new session plus prepared runtime. The helper does not start the runtime, so apps can attach rendering, audio, and input components before packet ingest begins.
- the first emitted session metric snapshot now includes `sessionOpenDurationMs`
- forwarded session metrics now also include input packet counts and local input queue/send latency, transport missing/reorder/discontinuity counters, reconnect-attempt counts, decode/render/playback counters, decode latency metrics, host-provided video processing latency metrics, and audio underrun counts from the live media pipeline
