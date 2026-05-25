# Pairing Protocol

This document defines the pairing contract used by `swift-moonlight`.

Status:
- required for Sunshine
- required for Apollo
- partly observed from references

References:
- `refs/sunshine/src/nvhttp.cpp`
- `refs/apollo/src/nvhttp.cpp`
- `refs/moonlight-harmonyos/entry/src/main/ets/entryability/http/PairingManager.ts`

## Goal

Provide one high-level Swift operation:

```swift
let result = try await client.pair(hostID: host.id, pin: "1234")
```

Internally this operation is multi-step and stateful.

## High-Level Sequence

The pairing flow is an HTTP query-driven handshake with strict call ordering.

Transport note:
- current Sunshine and Apollo pairing requests are sent to the advertised external HTTP GameStream port
- hosts may also advertise a distinct `HttpsPort` in `serverinfo`, but that is not the default port for the existing `/pair` request flow implemented here
- reference Moonlight clients also include compatibility query fields on pairing requests: `devicename=roth` and `updateState=1`

Observed server-side phases from Sunshine:
1. `getservercert`
2. `clientchallenge`
3. `serverchallengeresp`
4. `clientpairingsecret`
5. `pairchallenge`

Sunshine rejects out-of-order requests and invalidates the pairing session on failure.

Apollo note:
- Apollo appears to keep the same core multi-step handshake but adds optional OTP-assisted entry points and richer post-pairing client policy.
- Apollo OTP auth is now implemented as an optional `getservercert` extension in the runtime pairing coordinator.

## Required Swift Types

```swift
public struct PairingSessionContext: Sendable {
    public var hostID: HostID
    public var uniqueID: String
    public var clientCertificateDER: Data
    public var pin: String
}

public struct PairingHandshakeResult: Sendable {
    public var state: PairingState
    public var serverCertificateDER: Data
}
```

## Endpoint-Level Contract

### Step 1: `getservercert`

Purpose:
- start a pairing session
- send the client certificate
- derive the AES key from host salt and user PIN
- receive the host certificate

Required inputs:
- `uniqueid`
- `phrase=getservercert`
- `clientcert`
- `salt`

Required outputs:
- paired flag
- server certificate as hex

Implementation rules:
- generate `uniqueid` per pairing attempt
- keep it stable across the full handshake
- `clientcert` is the hex-encoded PEM bytes of a self-signed X.509 client certificate in current Moonlight-compatible clients
- store the returned server certificate for subsequent verification
- derive the cipher key from host-provided salt and the PIN

### Step 2: `clientchallenge`

Purpose:
- prove possession of the derived key
- receive encrypted challenge response material from the server

Required inputs:
- `uniqueid`
- `clientchallenge`

Required outputs:
- encrypted challenge response

Implementation rules:
- use the AES key established from step 1
- do not advance if step 1 did not succeed
- the decrypted payload is `serverResponse || serverChallenge`, where `serverResponse` is one hash-length digest and `serverChallenge` is 16 bytes

### Step 3: `serverchallengeresp`

Purpose:
- return the decrypted and transformed server challenge response
- receive the server pairing secret

Required inputs:
- `uniqueid`
- `serverchallengeresp`

Required outputs:
- `pairingsecret`

Implementation rules:
- compute `hash(serverChallenge || clientCertificateSignature || clientSecret)`
- pad the hash to 32 bytes for SHA-1-era hosts
- AES-128-ECB encrypt that padded hash with the derived pairing key before sending `serverchallengeresp`
- treat `pairingsecret` as structured binary material
- split secret and signature exactly according to the handshake definition used by the host
- certificate verification uses the public key from the returned X.509 certificate

### Step 4: `clientpairingsecret`

Purpose:
- prove client identity and conclude pairing

Required inputs:
- `uniqueid`
- `clientpairingsecret`

Required outputs:
- final `paired` result

Implementation rules:
- if final paired state is false, treat the session as invalid and discard ephemeral state
- do not persist paired host state until the verification pass succeeds

### Step 5: `pairchallenge`

Purpose:
- verify the completed pairing exchange before persisting final paired state

Required inputs:
- `uniqueid`
- `phrase=pairchallenge`

Required outputs:
- final `paired` result

Implementation rules:
- treat failure here as a full pairing failure
- the default runtime pairing service performs this step

## State Machine

```swift
public enum PairingHandshakeState: Sendable {
    case idle
    case requestingServerCert
    case sendingClientChallenge
    case answeringServerChallenge
    case sendingClientPairingSecret
    case completed
    case failed(MoonlightError)
}
```

Rules:
- no step skipping
- no retry from the middle of a failed session
- full restart on ordering, crypto, or validation failure

## Error Handling

Treat these as hard failures:
- out-of-order call rejection
- missing `uniqueid`
- invalid certificate material
- cryptographic verification failure
- final `paired = 0`

Suggested mapping:
- `pairing.outOfOrder`
- `pairing.invalidResponse`
- `pairing.unsupportedOperation`
- `pairing.rejected`

## Persistence Rules

Persist separately:
- client identity material
- trusted host certificate
- pairing state

Apollo-specific note:
- pairing success on Apollo does not imply full launch or input permissions for that client

Do not persist:
- ephemeral challenge bytes
- per-session pairing secrets

## Unpair

Remote unpair is part of the pairing lifecycle.

Required behavior:
- call the host `/unpair` endpoint with the stable client `uniqueid`
- only clear local paired state after the remote unpair call succeeds

Current implementation:
- `MoonlightClient.unpair(...)` delegates to the configured pairing service when one is present
- `HTTPPairingTransport` supports `/unpair`
- `CryptoPairingClientService` issues runtime remote unpair requests using the client identity UUID

## Headless Test Cases

- successful pair against Sunshine
- successful pair against Apollo
- already-paired detection
- out-of-order replay rejection
- wrong PIN rejection
- unpair then re-pair

## Implemented Boundary

The current runtime pairing coordinator is `CryptoPairingClientService`.

Current Apple compatibility note:
- production builds now use `GeneratedRSAPairingCryptoProvider`
- it generates a Moonlight-compatible RSA self-signed X.509 certificate once per install, persists it locally, and uses RSA PKCS#1 v1.5 SHA-256 signatures
- this restores interoperability with Sunshine and Apollo pairing flows that reject raw public-key blobs

It is backed by:

```swift
public protocol PairingCryptoProvider: Sendable {
    func identityMaterial(for identity: ClientIdentity) throws -> PairingIdentityMaterial
    func signClientSecret(_ clientSecret: Data, for identity: ClientIdentity) throws -> Data
    func serverCertificateSignature(certificateHex: String) throws -> Data
    func verifyServerSignature(secret: Data, signature: Data, certificateHex: String) throws -> Bool
}
```

The implemented coordinator:
- generates salt, challenge, and client secret per pairing attempt
- derives the AES key from `salt + pin`
- decrypts and validates the server challenge response
- verifies the server pairing secret through the injected crypto provider
- performs the final `pairchallenge` request before returning `.paired`
- when `PairingAuth.otp(pin:passphrase:)` is used against Apollo, includes `otpauth = SHA256(pin + saltHex + passphrase)` on `getservercert`

Implemented crypto providers:
- `DigestPairingCryptoProvider` for deterministic tests and fixture-heavy flows
- `GeneratedRSAPairingCryptoProvider` for production RSA client signing and server-secret verification

Implemented key stores:
- `EphemeralPairingPrivateKeyStore` for in-memory runtime use
- `KeychainPairingPrivateKeyStore` for persisted Apple-platform private-key storage
