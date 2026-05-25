# Feature Baseline

The initial parity target is the currently shipped or described feature set in `refs/moonlight-harmonyos`.

Known items to verify and track:
- Encrypted pairing
- Video streaming
- Software decode fallback
- Hardware decode
- Audio playback
- Virtual controller / touch controls
- Physical controller support
- Xbox controller support
- DualSense controller support
- Apollo compatibility

v1 decisions:
- Host support: Sunshine and Apollo
- Decode policy: hardware first, software fallback
- Rendering: Metal
- Controllers: required in v1

This file should become the source of truth for:
- parity status
- platform-specific deltas
- unsupported or deferred items
