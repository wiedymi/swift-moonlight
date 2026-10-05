# ENet migration: high bitrate review

2026-10-05. User report: stutter and frame drops at 90 Mbps over Wi-Fi, at any
resolution. SwiftMoonlight `d0fcf54`, SwiftENet `173a6a9` / 0.2.0.

The sections below record the pre-fix investigation. There was a confirmed
ENet timer defect and extra CPU cost. Neither was shown to cause the reported
live stutter. The original local mixed packet test did not reproduce a packet
count shortfall. The fix status and new checks are recorded at the end.

## What changed

Video and audio still use separate UDP sockets. ENet carries control and input,
including keyframe requests and video repair status. The migration changed five
production files; the video parser, repair codec, decoder, and renderer did not
change in those commits. A control delay can still delay video recovery.

The old CENet adapter serviced C ENet under a lock. SwiftENet now services a Swift
peer on a native serial executor. Its retry delay follows the
[Moonlight fork](https://github.com/cgutman/enet/blob/c7353c059373f8d3fc83d451f8f1a477be3dc94e/protocol.c),
with bounded linear retries. The former vendored C client doubled retry delays.
The current policy matches the intended fork, but its CPU and packet cost under
sustained Wi-Fi loss needs a direct comparison. Changing retry delays without
that check could delay keyframe recovery.

## Confirmed timer defect

[Peer.nextServiceTime](https://github.com/wiedymi/swift-enet/blob/173a6a9862a3e06f2041a4ebc115641a3adb968e/Sources/SwiftENet/Peer.swift#L539)
checks whether a queued command fits the remaining reliable byte window. It does
not apply the blocked-channel rule used by `service`. It can return an immediate
deadline for a command that cannot be sent. `Client.pump` then schedules another
wake one millisecond later.

A deterministic probe negotiated a 4,096-byte window. Four reliable 872-byte
payloads and one 576-byte payload consumed 4,064 bytes. A queued 64-byte reliable
payload blocked channel zero; a later 16-byte unreliable payload fit the remaining
32 bytes but could not pass that earlier payload. The next deadline stayed zero
through 489 service calls from 11 to 499 ms, with no outgoing datagram.

This proves an unproductive timer path. It does not prove that the live stream
reached this queue state. A fix must use the same send eligibility rules for
service and deadline calculation; a larger fixed timer delay would hide the
error and add avoidable control latency.

## Queue CPU cost

The peer scans outgoing commands to calculate queued bytes, bytes in flight,
service work, ACK matches, and the next deadline. ACK removal can move array
entries. These costs grow when ACKs are delayed or lost.

A release/debug probe measured 2,000 service-plus-deadline calls per queue size,
without a retry becoming due. These are synthetic queue states, not measurements
of the user's live queue.

| Pending commands | Release us/call | Debug us/call |
| ---: | ---: | ---: |
| 1 | 0.10 | 3.46 |
| 64 | 2.86 | 54.45 |
| 512 | 35.29 | 432.05 |
| 4,096 | 319.52 | 3,734.00 |

At 512 pending commands, 1,000 such calls per second can use about 43% of one CPU
core in Debug. The timer defect can therefore amplify congestion. The sampled
local VVMoon executable was a Debug build, but it was idle: no active stream
stacks were captured. Its profile does not identify the live cause.

## Mixed packet test

The current `BoundUDPSocket` receiver ran beside the old/new encrypted control
adapters. Each run used 3,000 reliable 64-byte control packets at a target 1,000
packets/s, 48 channels, and at most 16 control packets in flight. A separate
process sent 1,200-byte video test datagrams in 60 bursts/s for three seconds.
At 90 Mbps it sent 28,125 datagrams. Receiver counts matched the sender in every
run. These video probes checked size and timestamp, not distinct sequence IDs.
Client order rotated over three repeats.

CPU includes the client driver, encryption, and raw video reader. It excludes
the external echo host and video sender. The test includes a 120 ms drain period.
It does not include video parsing, FEC, decoding, rendering, video encryption,
or Wi-Fi faults. Send and read timestamps use the same Mach clock.

| Build / video traffic | CENet CPU seconds | Swift CPU seconds | Video datagrams received per run |
| --- | ---: | ---: | --- |
| Release / no video | 0.574 | 0.667 | Not applicable |
| Release / 90 Mbps | 1.354 | 1.461 | 28,125 for both clients |
| Debug / 90 Mbps | 1.373 | 1.648 | 28,125 for both clients |

Swift used about 8% more total client CPU in the release mixed test and 20% more
in Debug. Median run p99 video read delay was 0.112 / 0.108 ms for C / Swift in
Release, and 0.109 / 0.117 ms in Debug. Control p99 RTT was lower for Swift.
This test shows CPU cost, but does not reproduce the reported stutter. It is not
a full-stream packet-integrity test.

Release uses Swift `-O` and baseline client C `-O3`; Debug uses Swift `-Onone`
and client C `-O0`. [Raw results and source hashes](benchmarks/enet-high-bitrate-review.json).

## Other paths to check

- `SessionRuntime.runVideoLoop` awaits FEC status sends and keyframe requests
  before reading more video. A slow control queue can make a video loss event
  worse. This coupling predates the migration; its delay now needs measurement
  with the new executor. Keyframe sends also flush video state, so moving that
  work must preserve send/flush order and report failures correctly.
- Video goes through socket, source, ingest, and depacketizer actors one packet
  at a time. At 90 Mbps, 1,200-byte datagrams imply about 9,375 packets/s before
  repair overhead. Small bounded read batches can reduce actor work. Buffering
  adds memory and latency, so bounds and read delay must be measured together.
- The video socket requests a 3,072,000-byte kernel receive buffer but does not
  check the result. That request succeeded on this Mac. Increasing it is not an
  evidence-based fix for this report.
- Urgent keyframe requests share the global reliable byte window with other
  channels. Their delay needs a check under a full window and bulk input.
- The ENet raw receive queue drops packets when its 256-entry limit is reached;
  it has no drop counter. Video packets do not use this queue. A control queue
  overflow can still delay recovery. Add visibility before increasing limits.
- The earlier performance checks did not combine full video processing, input,
  repair feedback, ACK loss, frame bursts, and CPU pressure in a long session.
  A three-second loopback run also does not cover later throttle changes.

90 Mbps is an encoder target, not the complete network rate. For example, 20%
repair data would add about 18 Mbps before transport overhead. The actual repair
percentage must be read from the session. Wi-Fi bursts remain a candidate;
the migration regression must still be checked on the same host and settings.
[Moonlight troubleshooting](https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting#video-is-choppy-or-laggy)
uses bitrate reduction and a wired/5 GHz comparison to test network limits.

## Original fix and validation order

1. Fix the timer eligibility mismatch and add the blocked-channel regression
   test. Verify that ACK arrival wakes progress and that no empty 1 ms timer
   cycle remains while the channel is blocked.
2. Reduce outgoing queue scans and repeated header reads. Keep one owner for
   queue state. If cached byte totals are needed, keep them inside that owner
   and verify their invariants on enqueue, ACK, retry, and close. Cached totals
   add state; the measured CPU reduction must justify it.
3. Remove control feedback waits from the video read path while preserving
   keyframe order, bounded feedback, and error handling. Then test bounded media
   read batches against the current one-packet path.
4. Add low-cost diagnostics: derive pending counts from their queues; count
   retries, empty timer wakes, raw queue drops, and time spent awaiting recovery
   sends. Observe receive gaps and actual presentation timing. Do not log packet
   contents, addresses, or pairing data.
5. Run the same full media workload with both transports at 40, 70, 90, and
   120 Mbps for 30–60 seconds. Include bursty loss, delayed ACKs, frame repair,
   input, and decoder load. Compare Release first, then Debug. Record video
   gaps, repair success, recovery-message delay, frame time, and CPU. Follow with
   the user's Wi-Fi stream and a wired comparison on the same host.

Acceptance: no unproductive timer cycle under blocked sends; bounded queue
memory; no loss of required control messages; lower CPU under ACK backlog; no
added video read delay from recovery feedback; and improved frame timing in the
reported 90 Mbps session. Raising queue limits or changing retry policy alone
is not enough evidence of a fix.

## Implemented fixes

SwiftENet 0.2.1 fixes the blocked-channel timer mismatch and an expired idle
ping deadline while a previous ping is waiting for its ACK. The same channel
eligibility rule is used for sending and scheduling. An ACK opens the window
immediately. An independent unreliable channel can send through a full reliable
window. Partial assembly and first-send timeouts constrain the next deadline.
The wire format, retry policy, negotiated window, and queue limits are unchanged.

The queue caches immutable command headers and maintains its own two byte
totals. This adds a small amount of memory per command in exchange for fewer
header reads and full scans. A four-word channel mask replaces a dynamic set.
Raw socket discards and queued/in-flight bytes are exposed through optional
metrics fields. Saved older metrics still decode. The discard count does not
measure loss in the network or kernel.

SwiftMoonlight reads up to 64 available UDP packets per actor call. One unread
batch is retained across frame returns. This adds bounded batch memory in
exchange for fewer actor calls; it never waits to fill a batch. It falls back
to one-packet reads for existing custom sources. Empty UDP datagrams do not end
the stream. Receive buffer setup tries smaller supported values when required,
and the actual kernel capacity can be queried.

Recovery sends use one active task outside the video read loop. A pending
keyframe request takes precedence over advisory FEC reports. Only 16 reports
wait; a newer report replaces the oldest when full. A monotonic cooldown
coalesces keyframe requests. State is cleared before sending, so a quick host
response is not cleared afterwards. Stop cancels pending recovery work. A
separate 100 ms control-metrics task keeps HUD data current without blocking
media reads; this adds a small fixed scheduling cost.

No arbitrary urgent-channel window bypass or retry-policy change was added.
Reliable control still obeys the host's shared window. Wi-Fi link capacity and
actual decode/presentation timing still need the user's device check.

## Fix validation

- SwiftENet: 38 local tests pass in Debug, Release, and Thread Sanitizer with
  Swift 6 and complete strict concurrency. Tests cover the timer faults, ACK
  progress, byte totals, older metrics, and counted oversized socket drops.
- SwiftMoonlight: 369 local headless tests pass in Debug and Release. New checks
  cover batch bounds/order, frame boundaries across batches, and all 100 video
  packets continuing to be read while a recovery send is deliberately held.
- The optional C/Swift check verifies each reliable payload and serial exactly
  once under ACK loss, delay, and reordering. Concurrent raw video packets have
  complete payload checks and distinct sequence checks, rather than counts alone.

Queue service plus deadline, five-sample medians on Apple M5 Max:

| Waiting commands | Release before / after (us) | Debug before / after (us) |
| --- | --- | --- |
| 64 | 1.265 / 0.478 | 16.507 / 9.056 |
| 512 | 9.620 / 5.114 | 153.317 / 79.664 |
| 4096 | 74.315 / 44.497 | 1234.494 / 664.179 |

The Release reduction is about 40–47% at 512–4096 commands. The small test
uses 500-byte reliable payloads, a full shared window, and fixed virtual time.
It measures service calls rather than total stream CPU. Raw data and the
repeatable script are in the SwiftENet repository.

The repeated 90 Mbps Release check used 60 bursts per second, 1,200-byte
synthetic video packets, and simultaneous control traffic. Each of 12 runs
received all 46,875 distinct video packets with no duplicate or invalid payload.
Three repeats alternate C and Swift order. Both clients use the same new batched
raw media reader; this isolates the transport comparison and is not directly
comparable to the earlier one-packet video reader measurements.

| Control case | C / Swift CPU seconds | C / Swift control p99 (ms) | C / Swift video read p99 (ms) |
| --- | --- | --- | --- |
| Encrypted, 3000 messages | 1.3919 / 1.5273 | 2.150 / 0.275 | 0.472 / 0.422 |
| ACK loss, delay, reorder, 500 messages | 1.0226 / 1.0065 | 430.639 / 50.389 | 0.408 / 0.402 |

These are medians. The fault proxy drops every twentieth datagram in each
direction and adds 5 ms delay, with extra delay on every seventh datagram to
cause reordering. All reliable control payloads were validated exactly once.
CPU includes the client crypto and full video payload validation; it excludes
the host, sender, and proxy. Wall time includes the five-second video load and
150 ms drain. The encrypted Swift case still uses about 10% more total CPU than
C in this specific workload. The queue improvement does not prove lower total
stream CPU than C. See [raw fix measurements](benchmarks/enet-high-bitrate-fix.json).

The raw video check does not perform RTP parsing, FEC, hardware decode, or Metal
presentation. Existing focused tests cover those library components; they do
not replace the same-host, same-device Wi-Fi check. No live stream was started
or restarted by this task.

Four additional 30-second 90 Mbps runs against the pinned Moonlight fork with
one negotiated channel received all 281,250 distinct video packets per run,
without duplicate or invalid payloads. The encrypted case validates 30,000
reliable control messages per client; the fault case validates 500 messages,
then continues video and periodic control pings under proxy faults. Swift
control p99 was 0.250 ms for encrypted traffic and 61.428 ms under faults,
compared with 2.143 ms and 125.885 ms for C. Total client CPU was 10.192 / 9.990
seconds (Swift / C) for encrypted traffic and 5.129 / 4.915 seconds under faults.
These are single long runs, not statistical CPU conclusions. See
[raw long-run checks](benchmarks/enet-high-bitrate-soak.json).

The recovery check also runs while `receiveNextFrame()` is still waiting.
A new test supplies 160 incomplete frames and keeps the source open; the
runtime requests a keyframe without waiting for a complete frame or source end.
This adds one bounded 100 ms monitor task. Both the monitor and frame loop use
one observation owner and mark events before suspension to avoid duplicates.

Read-loop completion cancels the associated periodic task. A regression test
checks that an ended video source does not send a later decoder-priming request.
