# Observed Behaviors

Use this file to record interoperability-relevant behavior that is not clearly specified in public docs.

Entry template:

## Title

- Status: observed | required-for-sunshine | hypothesis
- References:
  - repo/path
  - repo/path
- Summary:
  - plain-English behavior
- Impact:
  - what breaks if we get this wrong
- Test:
  - unit | fixture | integration

## HarmonyOS baseline features

- Status: observed
- References:
  - `refs/moonlight-harmonyos/README.md`
- Summary:
  - HarmonyOS README explicitly lists encrypted pairing, software decode, hardware decode, audio rendering, and a virtual controller, while noting gamepad support is not yet present.
- Impact:
  - This is the baseline parity target for the first implementation phase.
- Test:
  - feature matrix tracking plus integration coverage

## Apollo permission model differs from Sunshine

- Status: observed
- References:
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/apollo/src/input.cpp`
  - `refs/apollo/README.md`
- Summary:
  - Apollo introduces per-client permission masks that affect app launch, app visibility, and input acceptance after pairing.
- Impact:
  - A paired Apollo client may still be unable to launch apps or send specific input families. Treating pairing as equivalent to full authorization will produce incorrect client behavior and misleading errors.
- Test:
  - integration

## Apollo HTTP and HTTPS serverinfo can disagree for paired clients

- Status: observed live
- References:
  - live `apollo-host.local` Apollo serverinfo over HTTP and certificate-authenticated HTTPS
  - `refs/apollo/src/nvhttp.cpp`
- Summary:
  - Plain HTTP `serverinfo` can return `Permission=0` and `PairStatus=0` for a saved paired client certificate.
  - The same host queried over certificate-authenticated HTTPS can return `PairStatus=1` and the real permission mask, including mouse and keyboard input permissions.
- Impact:
  - Host refresh should prefer authenticated HTTPS `serverinfo` when a secure port is known, but retain HTTP fallback for discovery and unpaired hosts.
- Test:
  - `httpHostServiceFallsBackToPlainServerInfoWhenSecureServerInfoFails()`

## Apollo and Sunshine use different touch-port transforms

- Status: observed
- References:
  - `refs/apollo/src/input.cpp`
  - `refs/sunshine/src/input.cpp`
- Summary:
  - Absolute input and touch coordinate conversion logic diverges materially between Apollo and Sunshine.
  - Touch and pen packet bytes are still normalized client-surface coordinates; the divergence happens in host-side touch-port conversion after packet decode.
  - The Swift `HostInputCoordinateOracle` models the observed host-side transform so tests can cover Moonlight packet edge behavior, Apollo letterbox clamping, and Sunshine logical touch-port scaling without pre-transforming app input.
- Impact:
  - Reusing one host-side coordinate transform for both hosts will misplace cursor or touch interactions on at least one host family.
  - Pre-transforming Swift touch/pen packet bytes for Apollo would double-apply host geometry and misplace input.
- Test:
  - unit | fixture | integration

## Moonlight absolute mouse packets subtract one from reference dimensions

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/InputStream.c`
  - `refs/moonlight-ios/Limelight/Input/StreamView.m`
- Summary:
  - Reference clients queue absolute mouse coordinates using the client/video reference plane, but the input send path writes packet `width` and `height` as `referenceWidth - 1` and `referenceHeight - 1`.
  - The reference comment calls this a workaround for host-side rounding errors that can prevent the remote cursor from reaching screen edges.
- Impact:
  - Sending raw reference dimensions while also clamping `x/y` to `reference - 1` creates a small but visible coordinate drift, especially near edges and on high-resolution Apollo virtual displays.
  - Swift absolute mouse encoding now preserves the full coordinate reference for `x/y` and sends `reference - 1` in the packet dimensions.
- Test:
  - unit
  - integration

## Moonlight batches mouse motion and suppresses duplicate direct-pointer positions

- Status: observed
- References:
  - `refs/moonlight-common-c/src/InputStream.c`
  - `refs/moonlight-ios/Limelight/Input/StreamView.m`
- Summary:
  - Moonlight coalesces queued relative and absolute mouse motion before transport send rather than transmitting every intermediate move.
  - The direct-pointer UI path also avoids resending unchanged absolute coordinates because focus and modifier activity can generate spurious pointer callbacks.
- Impact:
  - Sending every mouse move reliably can queue stale motion and make the host cursor lag behind the local pointer even when coordinate math is otherwise correct.
  - Resending duplicate absolute positions can introduce errant host cursor motion around focus or modifier changes.
  - Coalesced relative deltas that exceed signed 16-bit packet fields are split into multiple packets rather than clamped, preserving fast pointer movement after short local scheduling delays.
  - UI input bridges must preserve the platform event order before handing events to the async sender. Reordering key up/down or mouse button/move events can look like sticky keys, repeated text, or delayed cursor motion even when packet encoding is correct.
  - Ordered app-side input queues may coalesce mouse motion, but accumulated relative movement must still be split into multiple relative events instead of clamped to one signed 16-bit packet.
  - The Swift library exposes `InputEventDispatchQueue` for this app-side ordered dispatch path so real integrations do not need to duplicate the test app's input scheduling logic.
  - The test app uses the default Moonlight-style 1 ms coalesced mouse delivery. Immediate mouse delivery remains available for diagnostics, but it can increase ENet packet queueing under sustained high-frequency pointer motion.
- Test:
  - unit | integration

## Packet counters are not enough to prove host cursor synchronization

- Status: observed
- References:
  - saved-paired Apollo desktop capture with `docs/input-visual-target.html`
- Summary:
  - Capture can open the pointer-reactive visual target page and send mouse packets, but packet counters and generic decoded-frame deltas do not prove that the host delivered pointer movement to the target surface.
  - In the current Apollo diagnostic run, absolute-sweep input packets advanced and could click host UI, but the click landed outside the visual target region because Apollo virtual desktop geometry offset the absolute mapping.
  - A later Apollo virtual-display run fetched the target page from the Mac helper server, but the streamed frame still showed only the virtual desktop wallpaper. The browser opened on another monitor, so the target fetch itself did not prove the streamed display contained the verifier.
  - A relative probe can produce a generic image delta, but the changed bounds may be unrelated desktop UI rather than the visual target page.
- Impact:
  - Treat `inputPacketsSent`, local queue latency, and broad image deltas as transport diagnostics only.
  - Production cursor parity requires target-region evidence from a pointer-reactive page or equivalent host-side verifier.
  - The visual-target page includes a visible color sentinel, and capture requires that sentinel before accepting expected-region evidence.
  - Physical mouse input should use relative capture by default; direct absolute mouse remains useful for touch-like diagnostics only until display-offset handling is proven.
- Swift handling:
  - Default Apollo production launches request `virtualDisplay=1` so Apollo creates a display for the requested stream mode instead of reusing a potentially offset physical desktop.
- Test:
  - live diagnostic | open gate

## Moonlight maps controller rumble to GameController haptic localities

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/Limelight.h`
  - `refs/moonlight-ios/Limelight/Input/HapticContext.m`
  - `refs/moonlight-ios/Limelight/Input/ControllerSupport.m`
- Summary:
  - Rumble and trigger-rumble callback values are persistent motor amplitudes until a later callback changes them or sets them to zero.
  - The Apple client maps low-frequency rumble to the left handle haptic locality, high-frequency rumble to the right handle locality, and trigger rumble to the matching trigger haptic localities.
  - RGB LED feedback is applied through `GCController.light` when available, and motion-report requests activate or deactivate manually controlled motion sensors.
- Impact:
  - Treating feedback as one-shot pulses makes controller haptics stop too early.
  - Using only the default haptic locality loses independent low/high and trigger feedback.
- Test:
  - unit
  - integration

## Moonlight launch queries advertise controller presence and persistence

- Status: observed-from-reference
- References:
  - `refs/moonlight-ios/Limelight/Network/HttpManager.m`
  - `refs/moonlight-harmonyos/entry/src/main/ets/entryability/http/NvHttp.ts`
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/apollo/src/nvhttp.cpp`
- Summary:
  - Reference Moonlight clients send `additionalStates=1`, `remoteControllersBitmap`, `gcmap`, and `gcpersist` on launch.
  - Sunshine and Apollo consume `gcmap` as the client gamepad mapping and expose it to the launched process through host environment state.
- Impact:
  - Omitting the launch-time controller bitmap can leave hosts without the same virtual-controller preparation path that official clients use, even if later controller packets are encoded correctly.
  - Keeping `remoteControllersBitmap` and `gcmap` aligned avoids advertising different controller presence through two compatibility fields.
- Test:
  - unit
  - integration

## Moonlight launch queries encode `surroundAudioInfo` without the audio magic byte

- Status: required-for-sunshine
- References:
  - `refs/moonlight-common-c/src/Limelight.h`
  - `refs/moonlight-ios/Limelight/Network/HttpManager.m`
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/sunshine/src/process.cpp`
  - `refs/apollo/src/process.cpp`
- Summary:
  - Reference clients build `surroundAudioInfo` from the audio channel mask and channel count only: `channelMask << 16 | channelCount`.
  - The lower 8-bit `0xCA` magic marker belongs to Moonlight's internal audio-configuration word and must not be sent in `/launch`.
  - Sunshine and Apollo decode the low 16 bits of `surroundAudioInfo` as the channel count for launched-app environment state.
- Impact:
  - Sending the full internal audio-configuration word makes stereo advertise `197322` instead of `196610`, so Sunshine/Apollo can see the channel count as `714` instead of `2`.
  - That can leave host-side app/audio policy without the expected `2.0`, `5.1`, or `7.1` environment state even when later RTSP audio fields are valid.
- Test:
  - unit
  - integration

## Sunshine and Apollo differ on `continuousAudio` launch handling

- Status: observed-from-reference
- References:
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/sunshine/src/rtsp.cpp`
  - `refs/sunshine/src/audio.cpp`
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/apollo/src/rtsp.cpp`
- Summary:
  - Sunshine parses `continuousAudio` from `/launch`, carries it through RTSP session configuration, and passes it into platform audio capture.
  - The checked-in Apollo reference does not parse or carry `continuousAudio`.
- Impact:
  - `continuousAudio=1` should still be emitted for Sunshine and possible future Apollo parity, but a current Apollo host may not produce audio packets during silent desktop/headless captures unless the host has an active audio source.
  - Audio-required Apollo smoke runs need a deterministic host-side audio source rather than relying on continuous-audio silence generation.
- Test:
  - integration

## Moonlight HDR launch queries include client capability metadata

- Status: observed-from-reference
- References:
  - `refs/moonlight-ios/Limelight/Network/HttpManager.m`
- Summary:
  - Reference Moonlight clients send `hdrMode=1` when requesting HDR-capable 10-bit video.
  - They also include `clientHdrCapVersion`, `clientHdrCapSupportedFlagsInUint32`, `clientHdrCapMetaDataId`, and `clientHdrCapDisplayData` in the launch query.
- Impact:
  - `hdrMode` is the host-side on/off request, but preserving the client capability fields improves launch-query parity and leaves room for real display capability metadata later.
  - A host may still report HDR disabled if the selected display, virtual display, OS HDR state, or host policy does not activate HDR.
- Test:
  - unit
  - integration

## App list entries advertise per-app HDR support

- Status: observed-from-reference
- References:
  - `refs/moonlight-ios/Limelight/Network/AppListResponse.m`
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/apollo/src/nvhttp.cpp`
- Summary:
  - Sunshine/Apollo app-list responses can include `IsHdrSupported` for each app entry.
  - Reference clients preserve that flag on app models.
- Impact:
  - App integrations can distinguish a host that supports HDR from an individual app entry that advertises HDR support.
  - Missing `IsHdrSupported` values should be treated as `false` rather than unknown enabled.
- Test:
  - unit

## Live serverinfo uses HTTP external port and PairStatus

- Status: required-for-sunshine
- References:
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/apollo/src/nvhttp.cpp`
- Summary:
  - Live Sunshine and Apollo `serverinfo` responses advertise `ExternalPort` as the GameStream HTTP port and may expose pairing state as `PairStatus` instead of `paired`.
  - On the plain HTTP `serverinfo` path, Sunshine and Apollo can still return `PairStatus=0` even when the client is already paired; the field becomes client-specific only on the HTTPS variant with `uniqueid`.
- Impact:
  - Assuming HTTPS on the external port or only parsing `paired` breaks host refresh against real servers even when discovery succeeds.
  - Treating HTTP `PairStatus=0` as authoritative will incorrectly downgrade paired hosts and block app list fetch or launch after a successful pair.
- Test:
  - fixture | integration

## Pairing `serverchallengeresp` is AES-encrypted client hash

- Status: required-for-sunshine
- References:
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/moonlight-ios/Limelight/Network/HttpManager.m`
  - `refs/moonlight-harmonyos/entry/src/main/ets/entryability/http/PairingManager.ts`
- Summary:
  - The client must hash `serverChallenge || clientCertificateSignature || clientSecret`, pad the digest to 32 bytes for SHA-1-era hosts, then AES-128-ECB encrypt that value before sending `serverchallengeresp`.
- Impact:
  - Sending the raw digest instead of the encrypted client hash lets the handshake progress far enough to receive `pairingsecret` but causes the final `clientpairingsecret` verification to fail on real Sunshine and Apollo hosts.
- Test:
  - unit | integration

## Live launch can return encrypted RTSP session URLs

- Status: required-for-sunshine
- References:
  - `refs/sunshine/src/nvhttp.cpp`
  - `refs/apollo/src/nvhttp.cpp`
  - `refs/moonlight-common-c/src/RtspConnection.c`
- Summary:
  - Live Sunshine and Apollo launches can return `sessionUrl0=rtspenc://...` rather than plain `rtsp://...`.
  - When that happens, RTSP messages must be wrapped in the Moonlight AES-GCM RTSP envelope using the `rikey` from `/launch`.
- Impact:
  - Treating `rtspenc://` as plain RTSP causes the app launch to succeed on the host but the client to fail immediately during RTSP setup, leaving the host busy with a launched app and no connected stream.
- Test:
  - integration

## Sunshine/Apollo reject placeholder RTSP `ANNOUNCE` SDP

- Status: required-for-sunshine
- References:
  - `refs/sunshine/src/rtsp.cpp`
  - `refs/apollo/src/rtsp.cpp`
- Summary:
  - A placeholder `ANNOUNCE` body such as `v=0` is rejected by live Sunshine/Apollo hosts with `RTSP/1.0 400 BAD REQUEST`.
  - The `ANNOUNCE` SDP must include the stream configuration fields the host parses, including audio channel count and mask, audio packet duration, audio/video QoS traffic types, packet size, viewport size, max FPS, bitrate bounds, configured bitrate, slices per frame, max reference frames, dynamic range mode, and color-space mode.
- Impact:
  - Reusing a dummy SDP body makes RTSP negotiation fail after successful `OPTIONS`, `DESCRIBE`, and `SETUP`, so the app appears to launch but the session never becomes usable.
  - Omitting fields that Apollo/Sunshine default differently can keep negotiation alive while changing host audio, bitrate, HDR, or FEC behavior in ways that are hard to diagnose from packet counters alone.
- Test:
  - integration

## Sunshine/Apollo video RTP packets use the RTP extension bit

- Status: required-for-sunshine
- References:
  - `refs/sunshine/src/stream.cpp`
  - `refs/apollo/src/stream.cpp`
- Summary:
  - Live Sunshine/Apollo video packets set the RTP extension bit and place the NVIDIA video header after the RTP extension header, not immediately after the fixed 12-byte RTP header.
  - On the tested host family the extension payload length is currently zero 32-bit words, so the live offset is `12 + 4`, but the parser must still honor the declared extension length.
  - On the tested Sunshine host family, the RTP payload-type field can legitimately be `0` because Sunshine leaves that field unset when constructing video RTP packets.
- Impact:
  - Parsing video packets as `12-byte RTP header + NVIDIA header`, or rejecting payload type `0` as non-RTP, produces black-video sessions without necessarily surfacing an immediate transport error.
- Test:
  - unit
  - integration

## Sunshine/Apollo 7.1.431 can use a 24-byte long first-packet frame header

- Status: required-for-sunshine
- References:
  - `refs/moonlight-common-c/src/VideoDepacketizer.c`
- Summary:
  - For the tested `appversion` family around `7.1.431`, the first byte of the first-packet frame header determines its length:
    - `0x01` -> 8-byte header
    - `0x81` -> 24-byte header
- Impact:
  - Stripping a fixed 8-byte first-packet header leaves non-video bytes in front of the Annex B bitstream and prevents correct frame reconstruction and decoder setup.
- Test:
  - unit

## Live Apollo/Sunshine video ingest can surface bare NV video packets at the parser boundary

- Status: confirmed
- References:
  - live paired host run against `apollo-host.local:47989`
- Summary:
  - On the tested live host, some video datagrams reached the parser beginning directly with `NV_VIDEO_PACKET` bytes instead of an RTP v2 header, for example `11 00 00 00 ...`.
  - Some bare video datagrams can also begin with a first byte whose top bits resemble RTP v2, for example `91 00 00 00 ...`, while still not carrying a valid video RTP payload type.
  - A strict RTP parser then fails with `RTP extension payload is truncated` even though the session has already entered `streaming`.
- Impact:
  - Rejecting the bare packet shape or classifying it as RTP using only the RTP version bits aborts video ingest despite successful session launch and control-channel startup.
- Test:
  - unit
  - integration
  - integration

## Apollo/Sunshine audio sockets can surface malformed or non-RTP datagrams during live sessions

- Status: observed
- References:
  - live paired host run against `apollo-host.local:47989`
- Summary:
  - On the tested Apollo/Sunshine host family, the audio socket can occasionally deliver datagrams that do not begin with an RTP v2 header, for example `10 00 00 00 ...`.
  - Treating those datagrams as fatal parser errors aborts otherwise healthy sessions before valid Opus packets are processed.
- Impact:
  - The audio ingest loop must ignore malformed or non-RTP datagrams on the live socket and continue waiting for valid RTP audio packets.
- Test:
  - unit
  - integration

## Moonlight media sockets keep host UDP mappings alive with sequenced pings

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/AudioStream.c`
  - `refs/moonlight-common-c/src/VideoStream.c`
- Summary:
  - Sunshine/Apollo media channels use host-provided ping payloads to keep UDP peer mappings active before and during RTP flow.
  - The 20-byte Sunshine-style ping payload carries an incrementing big-endian sequence number in bytes `16..<20`.
  - If no host ping payload is provided, legacy Moonlight behavior falls back to an ASCII `PING` datagram.
- Impact:
  - Reusing sequence `0`, stopping after a one-shot probe, or omitting the legacy fallback can leave audio/video sockets with no incoming packets even after RTSP negotiation succeeds.
- Test:
  - unit
  - integration

## Moonlight reference audio renderers consume interleaved PCM16 and honor negotiated Opus frame duration

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/Limelight.h`
  - `refs/moonlight-ios/Limelight/Stream/Connection.m`
- Summary:
  - Moonlight's reference audio callback contract carries an `OPUS_MULTISTREAM_CONFIGURATION` with `sampleRate`, `channelCount`, `streams`, `coupledStreams`, `samplesPerFrame`, and channel mapping.
  - The Apple-side reference decodes Opus into signed 16-bit interleaved PCM and queues `sizeof(short) * decodedFrames * channelCount` bytes for playback.
  - The reference renderer opts into arbitrary audio duration support instead of assuming fixed 5 ms packets.
- Impact:
  - Apple playback bridges should consume the decoded PCM as interleaved PCM16 rather than silently reinterpret it as float or planar audio.
  - Apple-side sinks must size playback buffers from the negotiated Opus `samplesPerFrame` contract instead of hardcoding a fixed decoded frame size.
- Test:
  - unit

## Sunshine/Apollo video frame boundaries depend on FEC block metadata, not only SOF/EOF flags

- Status: required-for-sunshine
- References:
  - `refs/moonlight-common-c/src/RtpVideoQueue.c`
  - `refs/moonlight-common-c/src/VideoDepacketizer.c`
  - `refs/moonlight-common-c/src/ControlStream.c`
- Summary:
  - Video packets carry both shard-level FEC metadata and multi-block FEC metadata.
  - Parity shards must not be submitted to frame assembly as video data.
  - Because parity shards still consume RTP sequence numbers, a depacketizer that drops them before sequence advancement will stall frame assembly and eventually report spurious packet loss.
  - `FLAG_EOF` only closes the frame on the last FEC block, not on earlier blocks of the same frame.
  - Clients that advertise the Moonlight FEC-status feature flag should send a best-effort `0x5502` frame FEC status report on the generic control channel when a FEC-described frame is unrecoverable.
  - The frame FEC status payload uses big-endian fields even though many Gen 7 control packets use little-endian payloads.
- Impact:
  - Treating every `EOF` as a real frame end, feeding parity shards into frame reconstruction, or dropping parity shards without advancing sequence tracking produces black-video or corrupted-video sessions even when RTSP and UDP transport are otherwise correct.
  - Advertising FEC status support without sending status reports gives Sunshine/Apollo less packet-loss detail for adaptive behavior and makes loss diagnostics weaker.
- Test:
  - unit
  - integration

## Decoder bad-data failures request IDR instead of ending the stream

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/Limelight.h`
  - `refs/moonlight-common-c/src/VideoDepacketizer.c`
  - `refs/moonlight-ios/Limelight/Stream/VideoDecoderRenderer.m`
- Summary:
  - Moonlight's decoder-renderer callback can report that submitted data could not be processed and requires a fresh IDR frame.
  - The common depacketizer responds to that decoder status by requesting decoder refresh rather than treating the stream as permanently failed.
  - The iOS renderer returns that status for failed format-description, sample-buffer, or display-layer paths.
- Impact:
  - A transient `VideoToolbox` bad-data error after packet loss should not immediately mark the session as unexpectedly disconnected.
  - Swift counts recoverable bad-data decode failures, emits a warning, and requests a new keyframe through the control channel so integrations can keep the stream alive while diagnostics remain visible.
- Test:
  - unit
  - integration

## Moonlight-style ENet control streams use reliable periodic ping for RTT refresh

- Status: required-for-sunshine
- References:
  - `refs/moonlight-common-c/src/ControlStream.c`
- Summary:
  - Moonlight sends a client-to-host `0x0200` periodic control ping on the generic control channel about every 100 ms.
  - The payload is an 8-byte little-endian buffer: `u16 payloadLength = 4`, `u32 reservedOrTimestamp = 0`, then two zero padding bytes.
  - The ping uses reliable ENet delivery even though most loss-stat side traffic is best-effort.
  - ENet updates RTT/loss estimates when reliable packets are acknowledged, so the periodic ping is the steady-state source for control RTT telemetry.
- Impact:
  - Sending this ping unreliably can leave ENet RTT/loss stale during otherwise healthy streams, weakening input-latency diagnostics and future adaptive behavior.
  - Using a different payload shape may still keep the socket alive, but it no longer matches the reference Moonlight control-stream behavior.
- Test:
  - unit
  - integration

## Moonlight video FEC parity uses a compact GF(256) Reed-Solomon matrix

- Status: required-for-sunshine
- References:
  - `refs/moonlight-common-c/src/RtpVideoQueue.c`
  - `refs/moonlight-common-c/nanors/rs.c`
- Summary:
  - Video FEC uses systematic Reed-Solomon over GF(256).
  - For a block with `D` data shards and `P` parity shards, parity row `p` and data column `d` use the coefficient `inverse((P + d) xor p)`.
  - Recovery operates over protected video-packet bytes, not only decoder payload bytes; recovered data can include reconstructed `NV_VIDEO_PACKET` header fields and trailing zero padding.
  - Recovered packet bytes need sanity checks before being submitted to the depacketizer: first data shard should have SOF, last data shard should have EOF, middle data shards should contain picture data, and unexpected flag bits should reject recovery.
  - The depacketizer should attempt recovery at the missing RTP sequence boundary using the current observed FEC block plus pending same-block shards before reporting the frame as unrecoverable.
- Impact:
  - A generic Reed-Solomon implementation with a different generator matrix can pass local encode/decode tests but fail to decode Sunshine/Apollo parity.
  - Recovering only codec payload bytes is insufficient because the missing packet's video header fields are part of the protected data needed for safe reinsertion.
- Test:
  - unit

## Apollo/Sunshine sessions can reach RTSP `PLAY` and still deliver zero media until the Gen 5+ control stream is started

- Status: required-for-sunshine
- References:
  - `refs/moonlight-common-c/src/Connection.c`
  - `refs/moonlight-common-c/src/ControlStream.c`
  - `refs/moonlight-common-c/src/RtspConnection.c`
- Summary:
  - On the tested Apollo/Sunshine host family, successful `/launch`, RTSP `OPTIONS`/`DESCRIBE`/`SETUP`/`ANNOUNCE`/`PLAY`, and live UDP media sockets are still not sufficient to receive video or audio.
  - Real Moonlight clients initialize and start the Gen 5+ control stream after RTSP negotiation and before the normal media runtime is considered established.
  - The current Swift client can reach a `streaming` UI state while observing zero control, video, and audio packets if that control-stream startup is missing.
- Impact:
  - Treating RTSP `PLAY` as equivalent to a ready stream produces black-screen sessions with empty runtime metrics, which can be misdiagnosed as a decoder or renderer failure even though no media has arrived.
- Test:
  - integration

## Apple VideoToolbox decode surfaces can arrive as compressed bi-planar YCbCr formats

- Status: observed
- References:
  - live paired host run against `apollo-host.local:47989`
  - `/Applications/Xcode.app/.../CoreVideo.framework/Headers/CVPixelBuffer.h`
- Summary:
  - On the tested macOS path, `VTDecompressionSession` delivered HEVC SDR frames as `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange` (`&8v0`) instead of plain `420v`.
  - On an HDR-requested Apollo stream with HDR mode reported disabled, `VTDecompressionSession` delivered `kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange` (`&xv0`) unless the decoder explicitly requested uncompressed output.
  - Those buffers still report two planes, but they are not RGB and must not fall back to `bgra8` handling in the Metal path.
- Impact:
  - Treating compressed bi-planar decode surfaces as unknown RGB buffers produces cyan/green garbage on screen even though the decoded `CVPixelBuffer` is otherwise valid and Core Image can render it correctly.
  - Apple-platform renderers must map compressed 8-bit bi-planar variants to the same luma/chroma Metal plane formats as their uncompressed NV12-style counterparts.
  - Packed 10-bit lossless surfaces are not safe to sample as ordinary 16-bit P010 containers. The VideoToolbox decoder now requests uncompressed `420v` for SDR and `x420` for HDR before Metal presentation.
- Test:
  - unit
  - integration

## HDR decode surfaces must not be presented as raw SDR YCbCr

- Status: observed
- References:
  - Apple CoreVideo color attachment keys
  - `refs/moonlight-common-c/src/ControlStream.c`
- Summary:
  - HDR streaming can produce 10-bit bi-planar YCbCr frames carrying BT.2020-family color.
  - Presenting those samples through the SDR BT.709 path makes the image too bright and shifts colors.
  - SDR and HDR bi-planar presentation must honor CoreVideo range and matrix attachments. Live Apple decode surfaces may advertise BT.601, BT.709, or BT.2020 YCbCr matrices; using one hardcoded full-range matrix is not safe.
- Impact:
  - HDR correction needs to be validated from real decoded `CVPixelBuffer` attachments before enabling true HDR/EDR output. Incorrect PQ, range, or matrix assumptions can make both HDR and SDR presentations visibly worse.
  - The Metal display shader now applies video/full range scaling, BT.601/BT.709/BT.2020 matrix selection, and conservative PQ/HLG-to-SDR fallbacks for non-EDR BGRA presentation.
  - The PQ fallback maps BT.2020 linear RGB into BT.709 output space and applies a soft highlight shoulder instead of clipping everything above SDR reference white.
  - The HLG fallback applies the BT.2100 HLG inverse OETF, maps BT.2020 into BT.709 when needed, and uses the same soft SDR highlight shoulder as the PQ path.
  - Automatic Metal presentation is now the default. It keeps SDR streams on a `bgra8Unorm` drawable and sends requested HDR streams to an EDR `rgba16Float` drawable when display capabilities are not supplied. This lets apps that set only the stream HDR preference use EDR output.
  - `MetalPresentationConfiguration(dynamicRangeMode: .extendedDynamicRange)` opts into an `rgba16Float` drawable, extended-linear sRGB layer colorspace, and EDR-capable layer flags so apps can validate true EDR output explicitly.
  - `MetalPresentationConfiguration(dynamicRangeMode: .automatic, edrCapabilities:)` only enables that EDR path for HDR `VideoFormat` values when the app-provided display capabilities report EDR headroom above SDR. Apps can use this to keep the shader's SDR tone map on displays without EDR.
  - A requested HDR stream is not enough to infer BT.2020 output. If the decoded frame advertises SDR transfer metadata and no recognized matrix attachment, the Metal path keeps SDR matrix fallback instead of applying BT.2020.
  - The test app and capture tool still log decoded pixel-buffer format, range, matrix, transfer function, and propagated CoreVideo color attachments so live Apollo/Sunshine behavior can be compared before enabling EDR automatically.
  - A live Apollo HDR-requested capture produced 10-bit HEVC surfaces while still reporting HDR disabled and SDR transfer metadata; HDR verification must check metadata, not just bit depth.
  - Requesting uncompressed VideoToolbox output changed that Apollo capture from `&xv0` to `x420` and reduced Metal-vs-reference PNG deltas from visibly broken output to the same small range as SDR captures.
  - A later Apollo HDR-required capture produced mixed startup metadata: the first `x420` frame carried SDR `SMPTE_C` / `ITU_R_709_2` / `ITU_R_601_4` attachments, then Apollo sent HDR enabled and subsequent `x420` frames carried PQ transfer plus BT.2020 primaries/matrix.
  - Another saved-paired Apollo HDR-required capture reported HDR disabled and produced only SDR-tagged `x420` frames. Treat this as host/display HDR activation state, not active HDR, even though the launch query requested HDR and the decoder emitted 10-bit surfaces.
  - Renderer color conversion therefore has to be selected per decoded frame rather than cached from the launch HDR request or from the first decoded frame.
- Test:
  - unit
  - integration

## Presented-video geometry and absolute input geometry must match

- Status: observed
- References:
  - Apollo virtual-display testing
  - Metal test-app presentation path
- Summary:
  - The default Metal layer renderer presentation mode is `.stretch`, which presents video into the full stream layer.
  - The renderer also exposes opt-in `.aspectFit` and `.aspectFill` modes for app surfaces that need aspect preservation.
  - With default `.stretch`, direct absolute mouse mapping must normalize against that same full layer, not an independent aspect-fit rectangle, or the host cursor drifts when the window aspect differs from the negotiated stream aspect.
  - Resizing the local stream window changes presentation size and input mapping immediately, but the host stream resolution is negotiated during launch. Changing Apollo virtual-display resolution requires a new launch/session with a new requested resolution.
  - The test app uses debounced `MoonlightClient.restartSession(...)` relaunches on stream-window backing-pixel size changes when the `Window` resolution preset is active. This is an explicit restart path, not mid-stream renegotiation.
- Impact:
  - The test app uses the full surface for direct pointer coordinates.
  - Apps that choose `.aspectFit` or `.aspectFill` must route absolute pointer coordinates through the same visible/cropped video geometry. `MetalPresentationGeometry` exposes that geometry so integrations can share renderer math instead of duplicating it.
  - The `Window` resolution preset resolves to the stream window backing-pixel size at launch so Apollo virtual displays can be requested at the actual stream-window size.
  - Integrations that want host resolution to follow local window size should use `MoonlightClient.restartSession(...)` until a real protocol renegotiation path is implemented.
  - Interactive video surfaces should start with the default 1 ms coalesced mouse delivery and only switch to immediate delivery when local metrics show batching, not transport queueing, is the bottleneck.
- Test:
  - integration

## Apple keyboard input must be translated to Moonlight virtual-key values before packet encoding

- Status: observed
- References:
  - `refs/moonlight-common-c/src/InputStream.c`
  - `refs/sunshine/src/platform/macos/input.cpp`
- Summary:
  - Moonlight keyboard packets carry Win32 virtual-key values, not AppKit or Carbon virtual key codes.
  - Apple clients therefore need a platform-to-Moonlight translation layer before constructing `NV_KEYBOARD_PACKET`.
- Impact:
  - Sending raw macOS virtual key codes produces missing keys, wrong punctuation, and broken modifier handling on real hosts even when the input channel itself is connected.
- Test:
  - unit
  - integration

## Captured macOS mouse deltas can be fractional before Moonlight packet encoding

- Status: observed
- References:
  - AppKit `NSEvent.deltaX` / `deltaY`
- Summary:
  - Captured mouse input on macOS can expose fractional movement deltas, especially with high-resolution pointers or trackpads.
  - Rounding each platform event independently can drop slow movement when every individual event is below one whole pixel.
  - AppKit trackpad relative `NSEvent.deltaY` is already in the direction expected by this macOS test app's Moonlight relative mouse packet path.
- Impact:
  - Do not apply the `GCMouseInput` vertical-axis inversion used by some controller/mouse APIs to AppKit mouse events.
  - Captured relative input should accumulate fractional remainder across platform events, then emit Moonlight integer relative-move packets once whole movement is available.
  - Oversized accumulated relative movement still needs to be split into multiple Moonlight packets rather than clamped.
- Test:
  - unit

## Server codec flags drive codec and HDR launch eligibility

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/Limelight.h`
- Summary:
  - `ServerCodecModeSupport` advertises H.264, HEVC, AV1, 10-bit, and 4:4:4 codec/profile support through bit flags.
  - HEVC Main10 and AV1 Main10 are the HDR-capable modes used by the current Swift validation path.
- Impact:
  - Launching with a requested codec or HDR mode that has no overlap with host flags can fail after host-side side effects or produce an unusable stream.
  - The Swift client now rejects codec/HDR mismatches after host refresh and before launch.
- Test:
  - unit

## Video loss accounting is frame/FEC-block oriented, not generic RTP-gap oriented

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/RtpVideoQueue.c`
  - `refs/moonlight-common-c/src/VideoDepacketizer.c`
- Summary:
  - Moonlight C queues video packets against the active frame/FEC block.
  - The reference derives the block's lowest sequence from the packet sequence minus FEC shard index, rejects packets outside the valid block range, and tracks holes behind the highest received sequence inside that block.
  - Because the block base comes from RTP sequence minus shard index, a client can form the block from non-SOF shards and recover a missing shard `0` before handing the frame to the decoder.
  - A packet that arrives ahead of the next contiguous sequence means there is a gap, but it is not itself an out-of-order packet. Out-of-order is a later packet filling a hole behind a higher sequence already observed.
  - When a later frame starts after a completed frame, the reference treats the frame gap as frame loss/recovery state rather than adding every RTP sequence between frames to the active block's missing-packet count.
  - If the first visible packet for a later frame is not SOF, the current FEC block's derived lowest sequence is the right base for packet-hole accounting and FEC-status `nextContiguousSequenceNumber`.
  - Once a frame has been completed, missing trailing parity sequence numbers should not stall the next frame's SOF behind the generic packet reorder window.
- Impact:
  - Swift video metrics should not inflate `reorderedVideoPackets` for normal forward gaps.
  - Swift missing-packet accounting should prefer current FEC-block holes when FEC metadata exists, instead of counting the distance to an unrelated later packet that triggered discontinuity recovery.
  - Swift FEC recovery should not require seeing SOF before it can observe same-block shards.
  - Inter-frame sequence jumps should remain visible through discontinuity/frame-loss diagnostics without pretending they are packet holes inside the just-completed frame.
  - The Swift depacketizer should advance immediately to a new SOF after a completed frame, while recording a discontinuity when frame indexes were skipped.
- Test:
  - unit
  - integration

## Video receive should not block behind decoder submission

- Status: observed-from-reference
- References:
  - `refs/moonlight-common-c/src/VideoStream.c`
  - `refs/moonlight-common-c/src/VideoDepacketizer.c`
- Summary:
  - Moonlight C uses a dedicated video receive thread to drain RTP packets into the RTP/FEC queue.
  - Decoder submission runs separately through a decoder thread or a bounded decode-unit queue unless the integration explicitly selects a direct-submit path.
  - The receive-side socket buffer is also sized for bursts, but that buffer is not a substitute for keeping the receive loop independent from decoder/render latency.
- Impact:
  - Swift runtime-created video services should keep socket receive and depacketization moving while decode/render for earlier frames is still in flight.
  - Decode/render submission must remain ordered even when receive runs ahead.
  - Backpressure still needs to be bounded so slow decoders do not allow unbounded frame work to accumulate.
- Test:
  - unit
  - integration

## Saved-pairing smoke runs may need host app cancellation before launch

- Status: observed
- References:
  - live Apollo smoke runs against `apollo-host.local:47989`
- Summary:
  - Repeated end-to-end smoke runs can leave the host with a stale or half-closed app session, especially after interrupted runs or control-channel shutdown failures.
  - Asking the host to cancel the current app before a new launch gives the next session a clean host-side lifecycle without discarding saved pairing state.
- Impact:
  - The headless smoke harness exposes `SWIFT_MOONLIGHT_TEST_CANCEL_BEFORE_LAUNCH=1` and reports `preLaunchCancelAttempted` so repeated saved-device tests can opt into the cleanup step.
  - This is a harness lifecycle guard, not a replacement for correct stream shutdown or restart handling in product integrations.
- Test:
  - unit
  - integration

## Swift ENet replacement

References: bundled ENet 1.3.18 at parent commit `3ae6b69`; MIT Moonlight ENet
fork `c7353c059373f8d3fc83d451f8f1a477be3dc94e`.

- The old bundle is standard ENet-style code, not the Moonlight patched fork.
- The Moonlight fork uses a 900-byte default MTU, rounded RTT updates, bounded
  linear retry delays, and socket waits that respect retry deadlines.
- These transport rules are described in `docs/binary/ENET.md` before the Swift
  implementation. Host/application control messages and encryption stay above
  the ENet engine.
- The optional reference check tests exact echo bytes against standard ENet and
  the pinned Moonlight fork. The check is local transport evidence, not a claim
  of full Sunshine/Apollo or device validation.
