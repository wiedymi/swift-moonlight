# Swift ENet validation

Historical embedded-engine result. The current package integration is in
[SWIFT_ENET_PACKAGE.md](SWIFT_ENET_PACKAGE.md). Source hashes and test counts below
apply to the earlier implementation.

This report records the first Swift implementation. The later optimization,
current checks, and longer comparison are in [ENET_CPU.md](ENET_CPU.md).

Date: 2026-10-05. Branch: `feat/swift-enet`. Base:
`3ae6b69cc4cad054d5ece2ef1f9ab1daf24dd0de`.

The package now uses a Swift ENet client. CENet and its package target are
removed. Control and input still share one connection. Control encryption and
media transport keep their existing behavior. See [the wire contract](binary/ENET.md).

## Scope and design choices

- One client peer covers the Sunshine/Apollo use case. This is not a general
  ENet server library. Compression, custom checksums, and broadcast are excluded.
- A deterministic peer owns protocol state. An actor owns socket use, timers,
  application packets, and encryption sequence. Retries keep the same encoded
  bytes. They do not encrypt a second time.
- The receive loop and retry timer run without application polling. This adds
  actor and task costs but prevents a waiting reader from stopping retries.
- Messages are limited to 1 MiB; each application queue is limited to 4 MiB.
  These limits are smaller than general ENet defaults. A retained reliable
  fragment cannot expire silently; the connection fails if it cannot complete.
- Hostnames with both address families try IPv4 first, as before. Explicit IPv6
  works. There is no automatic family switch after a handshake timeout.
- Cancellation returns during address lookup. The system lookup can still finish
  on its worker; a socket made after cancellation is closed.
- Direct callers must now `await` the ENet session constructor, socket factory,
  and session close. The high-level client API remains unchanged.

## Checks

Both debug and release `swift test` runs pass: **381 tests** each. The 26 ENet
checks cover wire bytes, all command layouts, truncation, malformed flags,
10,000 malformed datagrams, negotiation, ordering, duplicate removal, reliable
and unreliable fragmentation, queue limits, shared byte-window fairness,
lost/duplicate ACKs, retry bytes, timeout, RTT/loss metrics, 16-bit sequence and
timestamp wrap, IPv4/IPv6, cancellation, and close.

Both builds pass with default Xcode DerivedData:

```sh
xcodebuild -scheme SwiftMoonlight -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SwiftMoonlight -destination 'generic/platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The independent C echo host accepts the Swift client using both the old bundled
ENet and the MIT Moonlight fork at
`c7353c059373f8d3fc83d451f8f1a477be3dc94e`. All five workloads complete with
exact payload equality and no duplicate application packets. A separate
70,000-packet run with one negotiated channel checks reliable sequence wrap and
channel-zero fallback against the patched host.

## Performance method

Machine: Apple M5 Max, 64 GiB memory, macOS 27.2. Compiler: Apple Swift 6.4.
The harness compiles the actual old transport and CENet from the base commit,
then the actual new Swift transport with `swiftc -O -swift-version 6`.
The same async driver and C echo host serve both clients. Both use MTU 900.
The package and its tests do not need the C reference. The optional script
extracts or fetches reference code and removes its temporary build files.

Each normal workload sends 2,000 application packets with 16 packets in flight.
The fragmented workload sends 500 packets with four in flight. The fault workload
sends 500 packets with 16 in flight. The proxy drops every twentieth UDP datagram
in each direction, adds 5 ms per direction, and delays every seventh datagram
by another 5 ms. Unreliable packets are measured without faults.

The table shows the median of three independent runs. Client order alternates.
RTT is application echo time. Throughput counts completed application packets,
not UDP datagrams. CPU time is client user plus system time during the workload.
Peak RSS includes the whole small client process and its driver. It is not an
isolated transport allocation count. Encrypted traffic uses the existing v2
crypto with a synthetic key; the echo host returns the ciphertext unchanged.
This checks framing and client cost, not a Sunshine encryption exchange.

| Workload | Median RTT ms, C / Swift | p99 RTT ms, C / Swift | Packets/s, C / Swift | CPU ms, C / Swift | Peak RSS MiB, C / Swift |
| --- | ---: | ---: | ---: | ---: | ---: |
| Reliable 32 B | 0.519 / 0.512 | 1.099 / 1.001 | 27,261 / 28,620 | 73.1 / 113.3 | 6.41 / 6.80 |
| Unreliable 32 B | 0.411 / 0.406 | 0.490 / 0.504 | 38,628 / 38,596 | 53.2 / 75.6 | 6.39 / 6.70 |
| Encrypted reliable 256 B | 0.627 / 0.575 | 0.725 / 0.773 | 25,487 / 27,008 | 78.5 / 114.2 | 6.69 / 7.06 |
| Fragmented reliable 8 KiB | 0.442 / 0.590 | 0.545 / 0.736 | 8,750 / 6,684 | 56.5 / 107.9 | 6.39 / 7.17 |
| Reliable 32 B with faults | 12.567 / 11.810 | 421.014 / 222.174 | 533 / 747 | 65.4 / 92.0 | 6.44 / 6.80 |

Small-packet median latency is similar. Encrypted throughput is about 6% higher,
but CPU cost is about 45% higher and its p99 is slightly higher. Fragmented
throughput is about 24% lower, with about 91% more CPU time. The fault workload
has about 47% lower p99 RTT. RSS increases by about 0.3–0.8 MiB.
The Swift version is not a general performance improvement over CENet.

Raw results contain every run, source SHA-256 values, compiler, and baseline:
[standard comparison](benchmarks/enet-standard.json),
[patched-host checks](benchmarks/enet-moonlight-host.json), and
[one-channel sequence-wrap check](benchmarks/enet-sequence-wrap.json).

```sh
python3 scripts/enet-checks/run.py --output results.json
python3 scripts/enet-checks/run.py --count 500 --repeats 1 --moonlight-host --output patched.json
python3 scripts/enet-checks/run.py --count 70000 --repeats 1 --channels 1 --scenario loopback --moonlight-host --output wrap.json
```

These are short local transport tests. Scheduling noise affects the results;
three runs are not a statistical confidence interval. No device energy,
real-network capacity, video frame time, or live input latency is measured.

## VVMoon review still required

Keep the app integration separate. Point its package at this worktree or a
reachable revision after review. Build iOS Simulator and macOS. Then test
Sunshine and Apollo startup, controller/keyboard/mouse input, rumble, a long
encrypted stream, disconnect/reconnect, network loss, and IPv6 where available.
Compare app input latency, CPU, memory, and battery use against its current
package revision. A successful echo check does not prove a live stream works.
