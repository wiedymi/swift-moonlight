# swift-moonlight

[![GitHub](https://img.shields.io/badge/-GitHub-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/wiedymi)
[![Twitter](https://img.shields.io/badge/-Twitter-1DA1F2?style=flat-square&logo=twitter&logoColor=white)](https://x.com/wiedymi)
[![Email](https://img.shields.io/badge/-Email-EA4335?style=flat-square&logo=gmail&logoColor=white)](mailto:contact@wiedymi.com)
[![Discord](https://img.shields.io/badge/-Discord-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/zemMZtrkSb)
[![Support me](https://img.shields.io/badge/-Support%20me-ff69b4?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/vivy-company)

Pure Swift Moonlight-compatible client stack for Apple platforms.

This package focuses on protocol, transport, media, input, and runtime orchestration for Sunshine and Apollo hosts. App UI is intentionally kept outside the core library so consumers can build their own SwiftUI, UIKit, AppKit, or game-surface integrations.

## Status

Experimental. The package builds, has a broad headless test suite, and includes live-host smoke/capture tooling, but it is not a production-ready Moonlight client yet. Public APIs may change while interoperability gaps are closed.

See `docs/PARITY_ROADMAP.md` for the current production-readiness matrix.

## Features

- Pure Swift client/session API for Apple platforms
- Sunshine and Apollo host model with compatibility profiles and host quirks
- Bonjour discovery plus manual host entry
- Host info, app list, launch, RTSP negotiation, and UDP channel establishment
- Crypto-backed pairing with RSA identity persistence
- Apollo OTP-assisted pairing support
- Control-channel parsing and encrypted control framing
- Video/audio packet ingest with RTP/bare packet parsing and loss metrics
- VideoToolbox-first decode path with a pluggable fallback decoder boundary
- Metal renderer with SDR, HDR metadata, EDR opt-in, and presentation geometry helpers
- Opus decoder and AVAudioEngine-backed audio sink
- Semantic input encoding for mouse, keyboard, touch, pen, and controllers
- GameController integration boundary for Xbox and DualSense-class controllers
- Headless `swift-moonlight-smoke` and `swift-moonlight-capture` tools for real-host verification
- macOS SwiftUI test app for local interoperability testing

## Platforms

- iOS 17+
- macOS 14+
- tvOS 17+
- Swift tools 6.0+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wiedymi/swift-moonlight.git", branch: "main")
]
```

Then add the library target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        "SwiftMoonlight"
    ]
)
```

## Quick Start

```swift
import Foundation
import SwiftMoonlight

let storageDirectory = URL(filePath: "/path/to/app-support/swift-moonlight")
try FileManager.default.createDirectory(
    at: storageDirectory,
    withIntermediateDirectories: true
)

let configuration = try ProductionClientFactory.configuration(
    storageDirectory: storageDirectory,
    displayName: "My Moonlight App",
    credentialStorage: .keychain(.init(service: "com.example.moonlight"))
)

let client = MoonlightClient(configuration: configuration)

let host = try await client.addHost(
    .init(address: "192.0.2.50", port: 47989)
)

try await client.pair(hostID: host.id, pin: "1234")

let apps = try await client.fetchApps(hostID: host.id)
let desktop = apps.first { $0.name == "Desktop" } ?? apps[0]

let session = try await client.openSession(
    hostID: host.id,
    appID: desktop.id,
    configuration: .default1080p60
)

let runtime = try await client.prepareRuntime(for: session, hostID: host.id)
runtime.runtime.start()

// Attach renderer/decoder/audio components before or immediately after runtime startup.
// On Apple platforms, `AppleMediaComponents.attachRecommendedPlaybackComponents(...)`
// wires VideoToolbox, Metal, Opus, and AVAudioEngine for a CAMetalLayer surface.
```

## Apple Playback Components

For a Metal-backed app surface:

```swift
#if canImport(Metal) && canImport(QuartzCore) && canImport(AVFoundation)
try await AppleMediaComponents.attachRecommendedPlaybackComponents(
    to: session,
    device: metalDevice,
    layer: metalLayer,
    preferredDecodeMode: .hardwareFirst
)
#endif
```

## Running Tests

```bash
swift test
```

## Real Host Smoke

Headless smoke test:

```bash
SWIFT_MOONLIGHT_TEST_HOST=192.0.2.50 \
SWIFT_MOONLIGHT_TEST_PIN=1234 \
SWIFT_MOONLIGHT_TEST_APP_ID=desktop \
swift run swift-moonlight-smoke
```

Headless capture:

```bash
SWIFT_MOONLIGHT_TEST_HOST=192.0.2.50 \
SWIFT_MOONLIGHT_TEST_APP_ID=desktop \
SWIFT_MOONLIGHT_CAPTURE_DYNAMIC_RANGE=hdr \
SWIFT_MOONLIGHT_CAPTURE_CODECS=hevc,h264 \
swift run swift-moonlight-capture
```

Manual macOS test app:

```bash
./scripts/build-test-app.sh
```

Or generate and open the Xcode project:

```bash
./scripts/build-test-app.sh --open-project
```

## Docs

- `docs/SPEC.md` - implementation scope and acceptance criteria
- `docs/ARCHITECTURE.md` - module boundaries and dependency direction
- `docs/PARITY_ROADMAP.md` - current production-readiness matrix
- `docs/HEADLESS_TESTING.md` - smoke, capture, and fixture strategy
- `docs/FIXTURES.md` - fixture inventory and provenance rules
- `docs/BINARY_LAYOUTS.md` - index for exact packet layout docs
- `docs/OBSERVED_BEHAVIORS.md` - clean-room notes for undocumented host behavior
- `docs/APOLLO_COMPATIBILITY.md` - Apollo-specific compatibility notes
- `docs/api/` - developer-facing API contracts
- `docs/protocol/` - protocol sequencing notes
- `docs/binary/` - packet and binary layout notes

## Repository Notes

- `refs/` contains upstream reference repositories as git submodules for behavioral study only.
- This repository is a clean-room Swift implementation under MIT. Do not copy, paste, or mechanically port GPL reference code.
- Opus is bundled as `Vendor/COpus.xcframework` and can be rebuilt with `./scripts/build-opus-xcframework.sh`.
- ENet is vendored under `Vendor/ENet`.

## License

MIT
