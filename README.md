# swift-moonlight

Pure Swift Moonlight-compatible client stack for Apple platforms.

Apple packaging note:
- Opus is bundled as a repo-managed static XCFramework at `Vendor/COpus.xcframework`
- Rebuild it with `./scripts/build-opus-xcframework.sh`
- This avoids host-local Homebrew or `pkg-config` dependencies for app builds

License:
- MIT

Initial scope:
- iOS
- iPadOS
- macOS

Rendering:
- Metal for production frame rendering on Apple platforms

Target parity baseline:
- Feature parity with the currently implemented subset in `refs/moonlight-harmonyos`

Project rules:
- This repository is a clean-room Swift implementation.
- Reference repositories under `refs/` are for protocol study, behavior confirmation, and gaps in public docs.
- Do not translate upstream GPL code line by line.
- Keep the implementation clean-room so the project can remain MIT-licensed.
- When behavior is learned from references rather than formal docs, record that in local notes or code comments at the boundary where it matters.

## Layout

- `refs/`: upstream reference repositories as git submodules
- `Sources/SwiftMoonlight/`: pure Swift implementation
- `Tests/SwiftMoonlightTests/`: tests
- `docs/`: architecture, protocol notes, and clean-room records

Core project docs:
- `docs/SPEC.md`: internal implementation spec
- `docs/ARCHITECTURE.md`: codebase and module boundaries
- `docs/HEADLESS_TESTING.md`: test strategy and CI model
- `docs/FIXTURES.md`: required fixture inventory and provenance rules
- `docs/APOLLO_COMPATIBILITY.md`: Apollo-specific compatibility tracking
- `docs/PARITY_ROADMAP.md`: production-readiness and Moonlight parity gap matrix
- `docs/BINARY_LAYOUTS.md`: index for exact packet layout docs
- `docs/OBSERVED_BEHAVIORS.md`: undocumented behavior tracking
- `docs/api/`: developer-facing API contracts and examples
- `docs/protocol/`: subsystem-level wire and sequencing contracts

Implemented runtime building blocks:
- host info, app list, launch, RTSP negotiation, and channel establishment
- live TCP RTSP transport implementation
- live UDP channel establishment with Sunshine-compatible ping probes
- periodic Sunshine-compatible media keepalives on live video/audio sockets
- crypto-backed pairing coordination with final `pairchallenge` verification
- production-grade P-256 pairing crypto with key-store-backed private key persistence
- typed pairing auth modes, including Apollo OTP-assisted pairing
- remote host-side unpair through the pairing service boundary
- compatibility profile and quirk modeling for Sunshine vs Apollo
- Bonjour-based `_nvstream._tcp` host discovery on Apple platforms
- persistent `FileHostStore` and `FileIdentityStore` implementations
- opt-in Apple Keychain-backed client identity and RSA pairing material stores for app integrations
- control-channel parsing and encrypted control framing
- semantic input encoding plus runtime input dispatch
- controller-source integration boundary for Apple `GameController`
- video/audio packet ingest and simple depacketization
- hardware-first Apple video path with `VideoToolboxDecoder`, `FallbackVideoDecoder`, `MetalRenderer`, and `MetalLayerTarget`
- `AppleMediaComponents` convenience wiring for the recommended Apple playback stack
- socket-backed runtime assembly through `ChannelSocketFactory` and `SessionRuntimeFactory`
- negotiated runtime encryption wiring for control-v2 plus encrypted video/audio ingest
- headless `IntegrationHarness` that reuses the public API, supports environment-backed smoke configuration, and reports structured pass/fail reasons
- `ProductionClientFactory` to assemble the current default app-facing stack
- `swift-moonlight-smoke` executable for environment-backed headless Sunshine or Apollo smoke runs
- `swift-moonlight-test-app` macOS SwiftUI executable for manual real-host testing

## Real Host Testing

Headless smoke test:

```bash
SWIFT_MOONLIGHT_TEST_HOST=192.168.1.50 \
SWIFT_MOONLIGHT_TEST_PIN=1234 \
SWIFT_MOONLIGHT_TEST_APP_ID=desktop \
swift run swift-moonlight-smoke
```

Headless capture with explicit stream settings:

```bash
SWIFT_MOONLIGHT_TEST_HOST=192.168.1.50 \
SWIFT_MOONLIGHT_TEST_APP_ID=desktop \
SWIFT_MOONLIGHT_CAPTURE_DYNAMIC_RANGE=hdr \
SWIFT_MOONLIGHT_CAPTURE_CODECS=hevc,h264 \
swift run swift-moonlight-capture
```

Manual test app:

```bash
swift run swift-moonlight-test-app
```

`swift run swift-moonlight-test-app` launches the SwiftUI target as a plain executable, which is useful for quick compile checks but does not behave like a normal macOS app bundle. For an interactive app with normal focus, activation, icon, and bundle metadata, use:

```bash
./scripts/build-test-app.sh
```

To generate and open the Xcode project instead:

```bash
./scripts/build-test-app.sh --open-project
```

The generated app target is macOS-only and is intended for local interoperability testing against real Sunshine or Apollo hosts. It supports:
- Bonjour discovery
- manual host entry
- PIN pairing
- Apollo OTP pairing via passphrase
- app list fetch
- live session startup with the current Metal + VideoToolbox + Opus playback stack

## Reference Repositories

- `refs/moonlight-harmonyos`: parity target for currently implemented end-user features
- `refs/moonlight-common-c`: protocol and transport behavior reference
- `refs/moonlight-ios`: Apple platform integration reference
- `refs/moonlight-android`: additional client behavior reference
- `refs/sunshine`: host-side behavior reference
- `refs/apollo`: Apollo host behavior reference
- `refs/moonlight-docs`: public Moonlight documentation

## Next Steps

1. Fill the remaining interoperability gaps such as deeper media recovery behavior and live end-to-end host coverage.
2. Expand Sunshine and Apollo smoke coverage on real hosts using the environment-backed `IntegrationHarness`.
3. Continue replacing remaining fixture-only protocol assumptions with captured interoperability evidence.
