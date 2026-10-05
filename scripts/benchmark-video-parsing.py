#!/usr/bin/env python3
"""Compare optimized Annex-B parsing with the pre-fix revision; keep no build files."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "Sources/SwiftMoonlight/Media/Video/AnnexBBitstream.swift"
BASELINE = "3051f020f6cfed454feaf729f206df1b27421940"
old = subprocess.check_output(["git", "show", f"{BASELINE}:{SOURCE}"], cwd=ROOT, text=True)
old = old.split("\n#if canImport(CoreMedia)")[0].replace("enum AnnexBBitstream", "enum LegacyAnnexBBitstream")
new = (ROOT / SOURCE).read_text().split("\n#if canImport(CoreMedia)")[0]
main = r'''import Foundation
public enum VideoCodec { case h264, hevc, av1 }
@inline(never) func measure(_ payload: Data, _ parse: (Data) -> Int) -> Double {
    let start = ContinuousClock.now
    var checksum = 0
    for _ in 0..<400 { checksum &+= parse(payload) }
    precondition(checksum > 0)
    let duration = start.duration(to: .now).components
    return (Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15) / 400
}
for size in [100_000, 187_500, 800_000] {
    var payload = Data([0, 0, 0, 1, 0x26, 1])
    payload.append(contentsOf: (0..<size).map { UInt8(truncatingIfNeeded: $0) })
    precondition(LegacyAnnexBBitstream.lengthPrefixedSample(from: payload) == AnnexBBitstream.lengthPrefixedSample(from: payload))
    var before: [Double] = []; var after: [Double] = []
    for _ in 0..<5 {
        before.append(measure(payload) {
            let sample = LegacyAnnexBBitstream.lengthPrefixedSample(from: $0)
            return sample.count + LegacyAnnexBBitstream.codecParameterSets(from: $0, codec: .hevc).count + Int(sample.last ?? 0)
        })
        after.append(measure(payload) {
            let sample = AnnexBBitstream.lengthPrefixedSample(from: $0)
            return sample.count + AnnexBBitstream.codecParameterSets(from: $0, codec: .hevc).count + Int(sample.last ?? 0)
        })
    }
    let baseline = before.sorted()[2]; let current = after.sorted()[2]
    print(String(format: "%d bytes: %.3f -> %.3f ms/frame (%.1fx)", size, baseline, current, baseline / current))
}
'''
with tempfile.TemporaryDirectory(prefix="stream-parser-bench-") as folder:
    root = Path(folder)
    for name, body in [("old.swift", old), ("new.swift", new), ("main.swift", main)]:
        (root / name).write_text(body)
    subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", str(root / "old.swift"),
                    str(root / "new.swift"), str(root / "main.swift"), "-o", str(root / "bench")], check=True)
    subprocess.run([str(root / "bench")], check=True)
