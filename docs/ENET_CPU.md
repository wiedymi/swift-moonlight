# Swift ENet CPU and strict concurrency

Historical embedded-engine result. The current package integration is in
[SWIFT_ENET_PACKAGE.md](SWIFT_ENET_PACKAGE.md). Source hashes and test counts below
apply to the earlier implementation.

Date: 2026-10-05. Branch: `feat/swift-enet`, based on `3ae6b69`.
This is the latest report. [The earlier report](ENET_PERFORMANCE.md) keeps the
first optimization results. CENet remains absent from package dependencies and tests.

## Changes and reason

A release `sample` capture of paced encrypted traffic showed native socket
callbacks, Swift stream operations, actor task scheduling, and timer tasks.
Waiting threads also appear, so the capture does not establish CPU percentages
for individual functions. Controlled comparisons below test the resulting change.

- The connection and both public adapter actors share the socket's native
  serial executor. Forwarding between those actors needs no executor change.
- The socket calls the connection directly on that executor. Production no
  longer uses a stream and a separate receive task to move raw datagrams.
- One reusable native timer replaces sleeping Swift tasks. An ACK can move the
  deadline later, so an obsolete retry need not wake the connection.
- All mutable socket data is inside `OSAllocatedUnfairLock`. Socket `Sendable`
  conformance is checked by the compiler. Cancellation and descriptor operations
  use the same lock; only the native source's cancel handler closes the descriptor.

No extra packet collection delay is added. Packet limits, encryption, reliable
application pings, independent reads, and retry behavior remain in place.
The connection actor still owns protocol state. Public adapter types stay actors.

The trade-off is a dependency on native serial-executor runtime support.
macOS 15, iOS/tvOS 18, and visionOS 2 or newer can check actor isolation from
native callbacks. Older supported systems schedule an actor task for each
notification. The CPU results below use the newer path. The older path builds
but still needs device testing. See Swift's
[custom executor isolation proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0424-custom-isolation-checking-for-serialexecutor.md).

## Swift 6 strict concurrency

`Package.swift` explicitly selects `swiftLanguageModes: [.v6]` for the package.
Swift 6 language mode requires complete concurrency checks; these are compiler
errors, not optional warnings. Validation also passes
`-Xswiftc -strict-concurrency=complete`. The benchmark compiler uses
`-swift-version 6 -strict-concurrency=complete -O` for all three clients.
There is no `@preconcurrency` or custom `@unchecked Sendable` in the production
ENet implementation. Other existing library platform wrappers are outside this
change. See the official
[Swift 6 data-race safety guide](https://swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/).

## Measurement method

Apple M5 Max, 64 GiB, macOS 27.2, Apple Swift 6.4. The same release driver and C
echo host are used for every client. Client order rotates between repeats.
CENet is the actual historical transport at `3ae6b69`; Swift-before is the
optimized Swift version before this CPU pass. The benchmark checks exact payload
equality, packet counts, and duplicates. CPU time is whole-client user plus
system time, including the driver and encryption; it excludes the host and proxy.

Each normal case sends 20,000 packets, with 16 in flight. Fragmented traffic
uses 5,000 packets and four in flight, MTU 900. Fault traffic uses 500 packets,
drops every twentieth UDP packet in each direction, adds 5 ms each way, and
adds another 5 ms to every seventh packet. Each case has six repeats per client.
Throughput counts application packets, not UDP packets. Tables use medians.

| Case | CPU us/packet, C / Swift | CPU reduction from previous Swift | CPU reduction from C | Packets/s, C / Swift | Median RTT ms, C / Swift | p99 RTT ms, C / Swift |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Reliable 32 B | 36.4 / 31.9 | 29% | 12% | 27,374 / 38,332 | 0.588 / 0.412 | 0.671 / 0.545 |
| Unreliable 32 B | 28.3 / 24.8 | 32% | 12% | 36,463 / 42,772 | 0.435 / 0.368 | 0.516 / 0.462 |
| Encrypted 256 B | 41.2 / 37.8 | 23% | 8% | 24,393 / 32,482 | 0.654 / 0.488 | 0.771 / 0.575 |
| Fragmented 8 KiB | 111.4 / 69.5 | 52% | 38% | 8,975 / 16,542 | 0.443 / 0.235 | 0.509 / 0.338 |
| Reliable 32 B with faults | 198.8 / 119.1 | 20% | 40% | 285 / 738 | 13.063 / 11.715 | 887.159 / 255.979 |

CPU time falls below CENet in these five local cases. Throughput rises by about
17–84% in the four cases without faults. Against the previous Swift version,
CPU time falls by 23–52% in those cases. Peak RSS remains about 0.3–0.8 MiB
above CENet and includes the whole driver.

Under faults, CPU time falls, but median throughput is 2% below previous Swift
and p99 RTT rises from 231 ms to 256 ms. No retry policy or timing limit changed.
These short runs depend on which UDP packets the deterministic proxy drops.
They establish interoperation, not a guaranteed improvement in loss latency.
CENet also uses its older retry policy, while Swift uses Moonlight retry behavior.

## Paced encrypted traffic

Six repeats send 6,000 encrypted 256-byte packets each at a target of 1,000 per
second. Independent producer and reader tasks allow up to 16 packets in flight.
All clients sustain about 1,000 packets/s. Median CPU seconds per six-second run
are 1.165 for CENet, 1.386 for previous Swift, and 1.200 for current Swift.
This is 13% less CPU time than previous Swift and 3% more than CENet.
Median RTT is 1.543 / 0.179 / 0.173 ms respectively.

The difference from CENet is small and remains subject to system scheduling
noise. Individual runs overlap. This supports a CPU reduction from previous
Swift, but does not establish a paced CPU advantage over CENet.
The driver uses a timer to pace each packet, so its scheduling cost is included.


## Validation and limits

All **385 tests** pass in both debug and release with complete strict
concurrency checks. All **30 focused ENet tests** pass with Thread Sanitizer;
no race report is emitted. The iOS Simulator and macOS package builds pass
using default DerivedData and Swift 6 language mode.

The socket tests assert that callbacks run on the socket queue. A real UDP test
withholds an ACK and checks an identical retry with no application reader or
sender. It also checks background delivery, read cancellation, and closing both
adapters. Bounds, ordering, encryption, and malformed packet tests still pass.

All five workloads pass against the pinned Moonlight C fork. A separate run
passes 70,000 reliable packets with one negotiated channel against that fork,
checking sequence wrap and channel-zero fallback. These interoperation runs
were made alongside build checks; their timings are not used in the CPU tables.
All saved benchmark source hashes match the final production files.

VVMoon's existing Debug and Release settings also select `SWIFT_VERSION = 6.0`
and `SWIFT_STRICT_CONCURRENCY = complete`. This was checked without changing
VVMoon or its package revision.

VVMoon integration, live Sunshine/Apollo streaming, device energy use, and
video frame time are not measured here. Do not equate these transport results
with the complete app's CPU use. Remaining costs include packet encryption,
socket calls, payload copies, and caller-to-transport executor changes.

## Evidence

- [Six-repeat comparison](benchmarks/enet-cpu.json)
- [Paced comparison](benchmarks/enet-cpu-paced.json)
- [Moonlight fork check](benchmarks/enet-cpu-moonlight-host.json)
- [Sequence wrap check](benchmarks/enet-cpu-sequence-wrap.json)
- [Previous optimized Swift source](benchmarks/enet-cpu-before.tar.gz), only
  four source files, for the optional third comparison. It is not a package input.

Raw files include compiler, machine, language mode, strict checking mode,
baseline revision, and SHA-256 of production source files. To repeat:

```sh
python3 scripts/enet-checks/run.py --count 20000 --fragment-count 5000 --repeats 6 --output cpu.json
python3 scripts/enet-checks/run.py --count 6000 --repeats 6 --rate 1000 --width 16 --scenario encrypted --output paced.json
python3 scripts/enet-checks/run.py --count 2000 --fragment-count 2000 --repeats 1 --moonlight-host --output host.json
python3 scripts/enet-checks/run.py --count 70000 --repeats 1 --channels 1 --scenario loopback --moonlight-host --output wrap.json
swift test -Xswiftc -strict-concurrency=complete
swift test -c release -Xswiftc -strict-concurrency=complete
swift test --sanitize=thread -Xswiftc -strict-concurrency=complete --filter 'enet|ENet'
```

For a third client, extract the four-file source archive into a temporary folder
and pass `--swift-baseline /path/to/folder`. Remove that folder afterward. The
harness removes its reference sources, executables, and module cache automatically.
