# Test Plan

This file tracks the concrete test inventory for `swift-moonlight`.

## Smoke Tests

### Sunshine smoke test

Pass conditions:
- host info fetch succeeds
- pairing succeeds or existing paired state is detected
- app list fetch succeeds
- launch request is accepted
- control channel is established
- input channel is established
- video channel receives packets for at least the configured observation window
- audio channel receives packets for at least the configured observation window when host audio is enabled
- session remains alive without unexpected disconnect for the configured observation window
- harness report failures list is empty

### Apollo smoke test

Pass conditions:
- same as Sunshine smoke test
- any Apollo-specific negotiation difference is recorded in `docs/OBSERVED_BEHAVIORS.md`
- harness report failures list is empty

## Unit Tests

- host info parsing
- app list parsing
- pairing transcript validation
- state machine transitions
- input packet encoding
- video packet parsing
- audio packet parsing

## Platform Builds

- Build the `SwiftMoonlight` library for visionOS device and simulator.
- Confirm native AudioToolbox Opus decoding compiles for each Apple target.
- Check stereo, 5.1, and 7.1 fixtures at 5 ms and 20 ms, lost-packet recovery,
  channel mapping, first-packet duration, and invalid configuration handling.
- Run the headless Swift test suite on macOS after platform changes.
- Test streaming, audio, and physical controllers in a visionOS app on a device
  before claiming runtime support. A platform build alone does not prove these
  paths work during a live session.

## Fixture Tests

- approved pairing transcripts
- approved control responses
- approved input packet fixtures
- approved video packet sequences
- approved audio packet sequences

## Integration Tests

- Sunshine pair/unpair
- Apollo pair/unpair
- Sunshine launch/connect/disconnect
- Apollo launch/connect/disconnect
- controller input smoke test

## Fault Injection

- delayed control responses
- dropped video packets
- missing keyframe recovery
- audio jitter / underrun handling
- transport disconnect during session

## Metal presentation checks

- GPU readback verifies that a fitted picture cannot repeat its top or left edges into empty space.
- SDR and EDR textures run through MetalFX spatial scaling without GPU errors.
- A restart transition retains the newest decoded frame and ignores old-stream frames until the next prepare.
- Mac and iOS Simulator app builds check device and standard-scaling paths.
- Live resize appearance and stream latency require later device review.
