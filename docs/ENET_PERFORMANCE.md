# Swift ENet optimization

Historical embedded-engine result. The current package integration is in
[SWIFT_ENET_PACKAGE.md](SWIFT_ENET_PACKAGE.md). Source hashes and test counts below
apply to the earlier implementation.

This report covers the first optimization pass. See [the latest CPU and strict concurrency report](ENET_CPU.md) for the current implementation and measurements.

Date: 2026-10-05. Work remains on `feat/swift-enet`, based on `3ae6b69`.
The results below compare the bundled CENet transport, the first Swift
implementation, and the optimized Swift implementation. CENet remains absent
from the package and its tests.

## Costs found and changes made

Two four-second `sample` captures at one-millisecond intervals inspected the
release client. The first used 200,000 small reliable packets. The second used
70,000 fragmented packets. Samples showed Swift task scheduling and stream
operations, UDP sends, and repeated `retainedBytes`/`retainedEntries` scans in
fragment acceptance. Waiting threads are present in the samples, so these
captures do not give exact CPU percentages for each function.

- Adapter methods now forward without entering an extra actor. The connection
  actor still owns all mutable connection state. Public adapter actor types stay.
- One socket notification covers packets already queued. The raw waiting queue
  remains limited to 256 packets. The actor services the whole read group once.
- ACKs share outgoing datagrams. They flush at 32 commands or at the end of the
  read group. There is no added wait to collect packets. Disconnect also flushes
  pending ACKs.
- The byte codec allocates each encoded command or datagram once. Its reader and
  writer use scoped buffer access, with explicit lengths and byte stores that
  do not depend on integer alignment. Payloads still copy when decoded, so
  retained small payloads cannot retain an arbitrarily larger raw datagram.
- Ordered payloads move directly to delivery. They do not enter a temporary
  message map or trigger a scan of retained packets.
- Reliable output commands keep their existing array storage. Service calls
  compact it only when commands leave. Empty fragment maps are not rebuilt.
- The first fragment reserves the whole declared message size and fragment
  count. Later fragments check their ranges locally and write into the final
  buffer. Completion moves that buffer; it does not sort pieces or copy them
  into a second buffer. Queue totals remain derived from their owners; there
  are no extra saved byte counters to keep in sync.

The reservation choice accepts fewer simultaneous incomplete messages under
the same 4 MiB and 8,192-entry limits. It prevents repeated global capacity
scans and bounds allocation before accepting the first fragment. The size,
offset, overlap, duplicate, sequence, timeout, retry, and encryption checks stay.
See [the wire contract](binary/ENET.md).

## Measurement method

Apple M5 Max, 64 GiB, macOS 27.2, Apple Swift 6.4. All clients use the same
release driver and C echo host, MTU 900. Each run checks exact payload equality
and rejects duplicate application packets. There are six runs per client per
workload, with client order rotated. The table uses the median across runs.

Normal workloads use 20,000 packets and 16 packets in flight. Fragmented traffic
uses 5,000 packets and four in flight. Fault traffic uses 500 packets and 16 in
flight; its loss, delay, and reorder settings match the
[first validation](ENET_VALIDATION.md). Throughput counts application packets,
not UDP datagrams. CPU time includes the whole client driver, encryption and
decryption, and transport. It excludes the C host and Python proxy.

| Workload | Packets/s, C / Swift | CPU us/packet, C / Swift | CPU reduction from first Swift | Median RTT ms, C / Swift | p99 RTT ms, C / Swift |
| --- | ---: | ---: | ---: | ---: | ---: |
| Reliable 32 B | 26,787 / 35,595 | 37.2 / 46.7 | 13% | 0.594 / 0.436 | 0.962 / 0.703 |
| Unreliable 32 B | 35,562 / 40,562 | 29.1 / 37.2 | 7% | 0.446 / 0.382 | 0.528 / 0.524 |
| Encrypted 256 B | 23,996 / 30,090 | 41.5 / 49.9 | 12% | 0.659 / 0.523 | 0.905 / 0.696 |
| Fragmented 8 KiB | 8,860 / 12,023 | 112.5 / 147.0 | 34% | 0.448 / 0.326 | 0.527 / 0.513 |
| Reliable 32 B with faults | 520 / 740 | 161.3 / 154.3 | -3% | 12.849 / 11.945 | 433.228 / 226.507 |

Throughput is higher than CENet in all five workloads. CPU time is still about
20–31% higher in the four workloads without faults. Against the first Swift
version, encrypted CPU time falls by 12% and fragmented CPU time by 34%.
The fault workload's negative reduction means a 3% CPU increase from the first
Swift version; it is not an improvement in that check. Peak RSS is about
0.3–0.8 MiB above CENet. Higher throughput partly uses more parallel execution,
so it must not be presented as lower CPU cost.

## Paced encrypted traffic

A separate check sends 3,000 encrypted 256-byte packets at a target of 1,000 per
second, with independent producer and reader tasks and a limit of 16 packets
in flight. All three clients reach about 1,000 packets/s. Across three runs,
CENet uses 0.741 CPU seconds, the first Swift version 0.853, and the optimized
Swift version 0.884. Median RTT is 1.400 ms, 0.223 ms, and 0.231 ms respectively.

This check does **not** show a CPU reduction at that rate. The small difference
between Swift versions needs more runs to distinguish it from scheduling noise.
It also includes the driver's pacing task. Lower CPU at maximum throughput
does not prove lower CPU, energy use, or temperature in VVMoon.

## Validation and remaining work

All **385 tests** pass in debug and release. iOS Simulator and macOS builds pass
with default DerivedData. Added checks cover sliced input buffers, empty
payloads, coalesced socket reads, combined ACK timestamps and command limits,
disconnect with pending ACKs, and reserved byte/fragment limits.

The optimized client passes all five workloads against the pinned Moonlight C
fork. It also passes 70,000 packets with one negotiated channel against that
fork, checking sequence wrap and fallback to channel zero.

Remaining costs include task/executor scheduling, socket system calls, decoded
payload copies, and packet encryption. Do not remove independent receive or
retry work to save CPU; that would change transport behavior. The next useful
check is a Time Profiler capture inside VVMoon at actual input rates, with the
same stream settings and host as its current CENet revision. Measure idle,
controller, mouse, and sustained-stream CPU separately. Use that result to
decide whether a shared serial executor or a scatter/gather socket path is
worth the added implementation and validation cost.

No live VVMoon, device energy, video frame-time, or network-capacity claim is
made here. Short local measurements remain subject to scheduling noise. The
fault result also includes the Swift client's Moonlight retry behavior; the
old bundled CENet uses its original retry behavior.

## Evidence and repeat commands

Raw files record every run, compiler, machine, baseline revision, and SHA-256
of the production sources:

- [Six-run comparison](benchmarks/enet-optimized.json)
- [Paced encrypted comparison](benchmarks/enet-optimized-paced.json)
- [Patched-host check](benchmarks/enet-optimized-moonlight-host.json)
- [Sequence-wrap check](benchmarks/enet-optimized-sequence-wrap.json)
- [First Swift source snapshot](benchmarks/enet-swift-before.tar.gz), a small
  compressed reference for the optional third comparison, not a package input.

```sh
python3 scripts/enet-checks/run.py --count 20000 --fragment-count 5000 --repeats 6 --output results.json
python3 scripts/enet-checks/run.py --count 3000 --repeats 3 --rate 1000 --width 16 --scenario encrypted --output paced.json
python3 scripts/enet-checks/run.py --count 2000 --fragment-count 2000 --repeats 1 --moonlight-host --output patched.json
python3 scripts/enet-checks/run.py --count 70000 --repeats 1 --channels 1 --scenario loopback --moonlight-host --output wrap.json
```

For the third client, extract the source snapshot into a temporary folder and
add `--swift-baseline /path/to/folder`. Remove that folder after the run. The
harness removes its own reference sources, binaries, and module cache.
