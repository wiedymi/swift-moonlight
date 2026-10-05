# SwiftENet package integration

SwiftMoonlight uses the public [swift-enet](https://github.com/wiedymi/swift-enet)
package at revision `4ce4ba7b67b5b0cdfb2c62a4d1048141520d3664` (tag `0.1.0`). The CENet target, dependency, and vendored
C/header files are removed. There is no second embedded Swift ENet engine.

SwiftENet owns the codec, peer state, bounded queues, native UDP socket, reads,
ENet idle ping, and retry timer. SwiftMoonlight owns startup A/B, encryption,
the shared encryption sequence for control and input, and reliable 100 ms
application pings. The Moonlight wrapper and adapters use the client's serial
executor. The application ping uses one task for the session; retries still use
one reusable native timer and do not create per-packet sleep tasks.

The extraction adds a second Swift module. This is the trade-off for a reusable
public package. The wrappers share its executor to avoid extra executor changes
in the packet path. The package rejects invalid channels; the Moonlight wrapper
keeps the previous channel-zero fallback for a host that negotiates one channel.

## Review

The package review checks wire parsing, bounds, ownership, reliable ordering,
fragment conflicts, native descriptor cleanup, actor isolation, and cancellation.
The public receive API now includes the channel ID. Conflicting reliable sequence
ranges are rejected. A failed close retains its error for readers.

Thread Sanitizer reported conflicts in the built-in executor callback path.
Swift jobs and native callbacks now enter through the same explicit serial
queue. Checks pass without suppressions. The newer runtime still enters native
callbacks directly; older supported systems schedule an actor task. Older-device
and live streaming checks remain for the user's integration review.

Swift 6 language mode is explicit in both packages. There are no unsafe build
flags or custom unchecked Sendable types in SwiftENet. Its MIT license, README,
wire contract, review record, tests, and macOS CI workflow are included. C
reference sources and build caches are not part of that package.

## Current performance check

Apple M5 Max, 64 GiB, macOS 27.2, Swift 6.4. Both clients use the same release
driver and C echo host, MTU 900. Client order rotates. Three repeats per client
use 5,000 normal packets with 16 in flight, 1,000 fragmented packets with four
in flight, and 500 fault packets. CPU time includes the complete client driver,
encryption, and decryption. It excludes the host and proxy. Payloads and counts
are checked. Tables use medians.

| Case | CPU us/packet, C / Swift | Packets/s, C / Swift | Median RTT ms, C / Swift |
| --- | ---: | ---: | ---: | ---: |
| Reliable 32 B | 38.2 / 36.1 | 26,150 / 34,041 | 0.614 / 0.451 |
| Unreliable 32 B | 30.1 / 29.4 | 34,304 / 37,278 | 0.462 / 0.419 |
| Encrypted 256 B | 42.4 / 41.9 | 23,658 / 29,669 | 0.674 / 0.532 |
| Fragmented 8 KiB | 122.7 / 78.9 | 8,138 / 14,584 | 0.484 / 0.264 |
| Reliable with loss/delay/reorder | 146.4 / 127.3 | 541 / 728 | 12.602 / 11.628 |

[Raw comparison](benchmarks/enet-package.json).

A separate three-repeat check sends 3,000 encrypted packets at 1,000 per second,
with independent producer and reader tasks, and at most 16 in flight. Both clients
sustain the target. Median CPU time is 0.646 s for CENet and 0.722 s for Swift
per three-second run, about 12% more for Swift. Median RTT is 1.345 / 0.191 ms.
This is a remaining paced CPU cost, despite higher maximum throughput. The
driver's per-packet pacing task is included. [Raw paced check](benchmarks/enet-package-paced.json).


These short local checks are subject to scheduling noise. They do not measure
VVMoon streaming CPU, device energy, or frame time. The Swift retry policy follows
the Moonlight fork; the historical CENet baseline uses its older policy.
[Earlier reports](ENET_CPU.md) describe the embedded implementation and are kept
as historical evidence.

## Validation

SwiftENet's 32 tests pass in debug, release, and Thread Sanitizer, with complete
strict concurrency checks. SwiftMoonlight's 364 tests pass in debug and release
against the published dependency revision. The first debug run after moving to
newer main changes failed to find a newly added video fixture; the fresh run
passes without a code change. iOS Simulator and macOS library builds pass with
default DerivedData.

All five workloads pass against the pinned Moonlight fork, and 70,000 packets
pass with one negotiated channel. The raw results are [here](benchmarks/enet-package-host.json)
and [here](benchmarks/enet-package-wrap.json). The optional host checks were run
before a final whitespace-only cleanup in two ENet source files. Their recorded
hashes describe those measured files. The final comparison and paced check use
the exact published package sources.

No live VVMoon stream or older-device check has been made in this task.

## Repeat checks

```sh
swift package resolve
swift test -Xswiftc -strict-concurrency=complete
swift test -c release -Xswiftc -strict-concurrency=complete
python3 scripts/enet-checks/run.py --count 5000 --fragment-count 1000 --repeats 3 --output package.json
python3 scripts/enet-checks/run.py --count 3000 --repeats 3 --rate 1000 --width 16 --scenario encrypted --output paced.json
python3 scripts/enet-checks/run.py --count 2000 --fragment-count 2000 --repeats 1 --moonlight-host --output host.json
python3 scripts/enet-checks/run.py --count 70000 --repeats 1 --channels 1 --scenario loopback --moonlight-host --output wrap.json
```

The harness reads the resolved SwiftENet checkout by default. `--enet-source`
can select a review checkout. It records hashes for the adapter and every ENet
source file, uses Swift 6 complete strict checks, and removes temporary C
sources, binaries, and its module cache.
