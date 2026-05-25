# Host Info And Apps Protocol

This document defines host refresh and app list fetching behavior.

Status:
- required for all interactive usage
- mixed specified and observed behavior

References:
- `refs/moonlight-common-c/src/Limelight.h`
- `refs/sunshine/src/nvhttp.cpp`
- `refs/apollo/src/nvhttp.cpp`
- `refs/moonlight-harmonyos/entry/src/main/ets/entryability/http`

## Goal

Expose clean high-level APIs:

```swift
let host = try await client.refreshHost(host.id)
let apps = try await client.fetchApps(hostID: host.id)
```

## Host Refresh Responsibilities

Refreshing a host must populate:
- name
- host kind
- pairing state
- app version strings where available
- session URL / RTSP URL where available
- codec capability flags
- input/touch/controller capability hints where available

Transport note:
- the current Sunshine and Apollo GameStream `serverinfo` and `applist` endpoints are served on the advertised external HTTP port
- `serverinfo` also reports a separate `HttpsPort`; when a secure port is already known, host refresh should try certificate-authenticated HTTPS `serverinfo` first, then fall back to plain HTTP for discovery and unpaired hosts
- live `serverinfo` responses may report pairing state as `PairStatus` instead of `paired`; parsers must accept both
- on Sunshine and Apollo, HTTP `serverinfo` may still report `PairStatus=0` even for a locally paired client; host refresh must not silently downgrade a stored paired host based on that response alone
- `applist` and `launch` use the advertised HTTPS port, not the external HTTP GameStream port

## Required Swift Types

```swift
public struct HostSnapshot: Sendable {
    public var host: MoonlightHost
    public var serverInfo: ServerInfo
}

public struct ServerInfo: Sendable {
    public var appVersion: String?
    public var gfeVersion: String?
    public var rtspSessionURL: String?
    public var codecSupportFlags: UInt32
    public var pairingState: PairingState
}
```

## Parsing Rules

- XML parsing must be tolerant of missing optional fields
- missing required fields should fail with `protocol.invalidServerInfo`
- host kind detection should use capability and version heuristics, not only branding strings
- raw server response should be recordable in fixtures for regression tests

## App List Responsibilities

Fetching apps must return:
- stable app ID
- display name
- hidden/system flags when available
- box art or metadata only if later supported, not required in v1

```swift
public struct RemoteApp: Sendable, Identifiable {
    public typealias ID = String
    public var id: ID
    public var name: String
    public var supportsHDR: Bool
}
```

Rules:
- preserve the host-provided app identifier exactly
- do not synthesize IDs from names
- parse `IsHdrSupported` when present; missing values default to `false`
- sorting for UI is a client concern, not a parsing concern

## Compatibility Rules

Sunshine and Apollo differences must be handled in:
- host response parsing adapters
- compatibility profile generation
- authorization and policy interpretation where Apollo exposes richer per-client behavior

Not in:
- UI code
- session core state machine

## Headless Test Cases

- parse host info fixture with full field set
- parse host info fixture with missing optional fields
- parse app list fixture
- detect paired vs unpaired state from host responses
- produce compatibility profile from Sunshine and Apollo snapshots
