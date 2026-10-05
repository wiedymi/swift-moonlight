import Darwin
import Dispatch
import Foundation

private struct Result: Encodable {
    let transport: String
    let count: Int
    let size: Int
    let reliable: Bool
    let encrypted: Bool
    let packetsPerSecond: Double
    let cpuSeconds: Double
    let peakRSSBytes: Int
    let medianRTTMs: Double
    let p95RTTMs: Double
    let p99RTTMs: Double
    let wallSeconds: Double
}

@main struct Driver {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let port = UInt16(args[1])!, count = Int(args[2])!, size = Int(args[3])!
        let reliable = args[4] == "1", encrypted = args[5] == "1", width = Int(args[6])!
        let label = args[7]
        let rate = args.count > 8 ? Double(args[8])! : 0
        let context: ControlEncryptionContext? = encrypted ? .init(key: Data(repeating: 0x5A, count: 16), version: .v2) : nil
        let session = try await ENetControlSession(remoteHost: "127.0.0.1", remotePort: port,
                                                   connectData: 0x1234, controlEncryption: context)
        let control = ENetControlChannelTransport(session: session)
        let input = ENetInputPacketTransport(session: session)
        var elapsed: [Double] = []
        elapsed.reserveCapacity(count)
        var outstanding: [UInt32: (time: UInt64, data: Data)] = [:]
        var seen: Set<UInt32> = []
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpuStart = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        let start = DispatchTime.now().uptimeNanoseconds
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(60)); await session.close() } catch {}
        }
        var sent = 0
        @MainActor func sendNext() async throws {
            let serial = UInt32(sent)
            var packet = Data([0x7A, 0xE1])
            var number = serial.littleEndian
            withUnsafeBytes(of: &number) { packet.append(contentsOf: $0) }
            packet.append(Data(repeating: UInt8(truncatingIfNeeded: serial), count: size - packet.count))
            outstanding[serial] = (DispatchTime.now().uptimeNanoseconds, packet)
            if encrypted { try await input.send(packet, channelID: UInt8(sent % 48), reliable: reliable) }
            else { try await control.send(packet: packet, channelID: UInt8(sent % 48), reliable: reliable) }
            sent += 1
        }
        let producer: Task<Void, any Error>? = rate > 0 ? Task { @MainActor in
            do {
                while sent < count {
                    let deadline = start + UInt64(Double(sent) * 1_000_000_000 / rate)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
                    while outstanding.count >= width { try await Task.sleep(for: .microseconds(100)) }
                    try await sendNext()
                }
            } catch { await session.close(); throw error }
        } : nil
        defer { producer?.cancel() }
        while seen.count < count {
            while rate == 0 && sent < count && outstanding.count < width { try await sendNext() }
            guard let received = try await control.receivePacket() else { throw MoonlightError(.invalidStateTransition, message: "Reference host closed") }
            let data: Data
            if let context {
                let decrypted = try ControlPacketCrypto().open(packet: received, sender: .client, context: context)
                if decrypted.packetType != 0x0206 { continue }
                data = decrypted.payload
            } else { data = received }
            guard data.count >= 6, data[0] == 0x7A, data[1] == 0xE1 else { continue }
            let serial = UInt32(data[2]) | UInt32(data[3]) << 8 | UInt32(data[4]) << 16 | UInt32(data[5]) << 24
            guard let expected = outstanding.removeValue(forKey: serial), expected.data == data,
                  seen.insert(serial).inserted else { throw MoonlightError(.invalidControlMessage, message: "Echo mismatch or duplicate") }
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - expected.time) / 1_000_000)
        }
        try await producer?.value
        let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        getrusage(RUSAGE_SELF, &usage)
        let cpu = seconds(usage.ru_utime) + seconds(usage.ru_stime) - cpuStart
        watchdog.cancel()
        let localPort = try await control.localPort()
        precondition(localPort != 0)
        await session.close()
        elapsed.sort()
        let result = Result(transport: label, count: count, size: size, reliable: reliable, encrypted: encrypted,
                            packetsPerSecond: Double(count) / wall, cpuSeconds: cpu, peakRSSBytes: Int(usage.ru_maxrss),
                            medianRTTMs: percentile(elapsed, 0.5), p95RTTMs: percentile(elapsed, 0.95),
                            p99RTTMs: percentile(elapsed, 0.99), wallSeconds: wall)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
    private static func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double { values[min(values.count - 1, Int(Double(values.count - 1) * fraction))] }
}
