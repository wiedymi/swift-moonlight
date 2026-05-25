# Pairing and Hosts API

This document defines host modeling, discovery, compatibility, and pairing interfaces.

## Hosts

```swift
public struct HostID: Hashable, Sendable {
    public var rawValue: UUID
}

public struct HostEndpoint: Sendable {
    public var address: String
    public var port: Int
}

public enum HostKind: Sendable {
    case sunshine
    case apollo
    case unknown
}

public struct MoonlightHost: Sendable {
    public var id: HostID
    public var name: String
    public var endpoint: HostEndpoint
    public var kind: HostKind
    public var pairingState: PairingState
    public var capabilities: HostCapabilities
}

public struct HostCapabilities: Sendable {
    public var supportsControllerInput: Bool
    public var supportsTouchInput: Bool
    public var supportsHardwareDecode: Bool
    public var supportsSoftwareDecodeFallback: Bool
    public var supportsInputOnlySession: Bool
    public var supportsOTPAuth: Bool
    public var requiresPerClientAuthorization: Bool
    public var supportedVideoCodecs: [VideoCodec]
    public var supportsHDR: Bool
}
```

```swift
public protocol HostStore: Sendable {
    func loadHosts() async throws -> [MoonlightHost]
    func saveHosts(_ hosts: [MoonlightHost]) async throws
}

public protocol HostDiscovery: Sendable {
    func discover(timeout: Duration) async throws -> [DiscoveredHost]
}
```

## Compatibility

```swift
public struct HostCompatibilityProfile: Sendable {
    public var kind: HostKind
    public var quirks: HostQuirkSet
}
```

Rules:
- compatibility detection happens once per refreshed host snapshot
- downstream modules receive a profile, not raw host-name checks

Current implementation note:
- `MoonlightClient.refreshHost(...)` now infers `HostKind`, `HostCompatibilityProfile`, and `HostCapabilities` from parsed server info
- `ServerCodecModeSupport` is mapped into `supportedVideoCodecs` and `supportsHDR` so stream launch validation can fail before host-side launch side effects
- when branding is absent from `appversion`, Apollo is inferred first from Apollo-specific policy fields such as `Permission`; otherwise Sunshine-family hosts are inferred from the broader GameStream server-info shape such as `GfeVersion` and codec flags
- Apollo capability inference currently enables OTP auth, input-only-session support, and per-client authorization flags
- `BonjourHostDiscovery` provides the current production `_nvstream._tcp` browse path on Apple platforms
- `MoonlightClient.discoverHosts()` now merges discovered hosts into `HostStore`
- `MoonlightClient.discoverHosts()` and `MoonlightClient.addHost(_:)` deduplicate by endpoint and preserve the paired or richer host record when stale duplicate rows exist
- `MoonlightClient.updateHostEndpoint(hostID:endpoint:)` is the supported recovery path when a saved paired host has a stale mDNS name but the user supplies a reachable IP/port; it preserves paired metadata rather than forcing a new pairing row

## Pairing

```swift
public enum PairingState: Sendable {
    case unpaired
    case paired
    case unknown
}

public struct PairingResult: Sendable {
    public var hostID: HostID
    public var state: PairingState
}

public enum PairingAuth: Sendable {
    case pin(String)
    case otp(pin: String, passphrase: String)
}

public protocol IdentityStore: Sendable {
    func loadOrCreateIdentity() async throws -> ClientIdentity
    func clearIdentity() async throws
}
```

Current storage implementations:
- `FileIdentityStore` persists client identity JSON on disk for local tooling and compatibility with existing stored test-app hosts.
- `KeychainIdentityStore` stores client identity in Apple Keychain through generic-password items.
- `FileRSAPairingIdentityStore` persists RSA pairing material JSON on disk.
- `KeychainRSAPairingIdentityStore` stores RSA pairing material in Apple Keychain and keys it by client identity.

## Usage

```swift
let host = try await client.addHost(.init(address: "192.168.1.10", port: 47989))
let refreshed = try await client.refreshHost(host.id)

if refreshed.pairingState != .paired {
    _ = try await client.pair(hostID: refreshed.id, pin: "1234")
}

if refreshed.capabilities.supportsOTPAuth {
    _ = try await client.pair(
        hostID: refreshed.id,
        auth: .otp(pin: "1234", passphrase: "apollo-passphrase")
    )
}
```

The transport-backed pairing service boundary is:

```swift
let pairingService = CryptoPairingClientService(
    transport: HTTPPairingTransport(client: httpClient),
    cryptoProvider: provider
)
```

Recommended current production-grade provider for app integrations on Apple platforms:

```swift
let provider = GeneratedRSAPairingCryptoProvider(
    identityStore: KeychainRSAPairingIdentityStore(
        configuration: .init(service: "com.example.myapp.moonlight")
    )
)
```

The file-backed provider remains useful for command-line tools, tests, and migration from earlier local builds.

Notes:
- `CryptoPairingClientService` performs the full multi-step handshake and final `pairchallenge` verification
- `PairingCryptoProvider` supplies client identity material, client signing, and server certificate verification
- the current production provider generates and persists a Moonlight-compatible RSA self-signed X.509 certificate and uses RSA PKCS#1 v1.5 SHA-256 signatures
- Sunshine and Apollo are currently treated as SHA-256 pairing hosts in the runtime coordinator
- Apollo OTP pairing is now modeled as `PairingAuth.otp(pin:passphrase:)`
- for Apollo hosts, `CryptoPairingClientService` computes `otpauth` as SHA-256 over `pin + saltHex + passphrase` and includes it on `getservercert`

Remote unpair uses the same boundary:

```swift
try await client.unpair(hostID: refreshed.id)
```

Current implementation note:
- when a transport-backed pairing service is configured, `unpair(...)` calls the host `/unpair` endpoint before clearing local paired state

## DX Constraints

- app code should not directly call `getservercert`, `clientchallenge`, or other protocol steps
- pairing should look like one operation with progress surfaced via events/logs
