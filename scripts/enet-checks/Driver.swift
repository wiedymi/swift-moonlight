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
    let video: VideoResult?
    let wallSeconds: Double
}

private struct VideoResult: Encodable, Sendable {
    let expectedPackets: Int
    let distinctPackets: Int
    let duplicatePackets: Int
    let invalidPackets: Int
    let p99ReadDelayMs: Double
    let receiveBufferBytes: Int
}

@main struct Driver {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "--video-sender" {
            try sendVideo(port: UInt16(args[2])!, bitrate: Double(args[3])!, duration: Double(args[4])!)
            return
        }
        let port = UInt16(args[1])!, count = Int(args[2])!, size = Int(args[3])!
        let reliable = args[4] == "1", encrypted = args[5] == "1", width = Int(args[6])!
        let label = args[7]
        let rate = args.count > 8 ? Double(args[8])! : 0
        let videoBitrate = args.count > 9 ? Double(args[9])! : 0
        let videoDuration = args.count > 10 ? Double(args[10])! : 3
        let videoExpected = Int(videoBitrate * 1_000_000 / 8 / 1200 * videoDuration)
        let videoSocket = videoBitrate > 0 ? try BoundUDPSocket(remoteHost: "127.0.0.1", remotePort: 9) : nil
        let videoReader: Task<VideoResult, any Error>? = videoSocket.map { socket in
            Task.detached {
                var seen: Set<UInt64> = []
                var delays: [Double] = []
                var duplicates = 0, invalid = 0
                let capacity = try await socket.receiveBufferCapacity()
                while !Task.isCancelled {
                    let batch = try await socket.receivePackets(maximumCount: 64)
                    if batch.isEmpty { break }
                    for data in batch {
                        guard data.count == 1200 else { invalid += 1; continue }
                        let serial = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
                        let sentAt = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard serial < UInt64(videoExpected), sentAt <= now,
                              data.dropFirst(16).allSatisfy({ $0 == UInt8(truncatingIfNeeded: serial) }) else { invalid += 1; continue }
                        if !seen.insert(serial).inserted { duplicates += 1 }
                        delays.append(Double(now - sentAt) / 1_000_000)
                    }
                }
                delays.sort()
                return VideoResult(expectedPackets: videoExpected, distinctPackets: seen.count,
                    duplicatePackets: duplicates, invalidPackets: invalid,
                    p99ReadDelayMs: delays.isEmpty ? 0 : delays[Int(Double(delays.count - 1) * 0.99)], receiveBufferBytes: capacity)
            }
        }
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
        let videoSender = Process()
        if let videoSocket {
            videoSender.executableURL = URL(fileURLWithPath: args[0])
            videoSender.arguments = ["--video-sender", String(try await videoSocket.localPort()), String(videoBitrate), String(videoDuration)]
            try videoSender.run()
        }
        defer { if videoSender.isRunning { videoSender.terminate() } }
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
        var video: VideoResult?
        if let videoSocket {
            while videoSender.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            guard videoSender.terminationStatus == 0 else { throw MoonlightError(.unsupportedOperation, message: "Video sender failed") }
            try await Task.sleep(for: .milliseconds(150))
            await videoSocket.close()
            video = try await videoReader?.value
        }
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
                            p99RTTMs: percentile(elapsed, 0.99), video: video, wallSeconds: wall)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
    private static func sendVideo(port: UInt16, bitrate: Double, duration: Double) throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MoonlightError(.unsupportedOperation, message: "Video sender socket failed") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let count = Int(bitrate * 1_000_000 / 8 / 1200 * duration)
        let bursts = Int(duration * 60)
        let start = DispatchTime.now().uptimeNanoseconds
        for burst in 0..<bursts {
            let deadline = start + UInt64(burst) * 1_000_000_000 / 60
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000) }
            for index in (count * burst / bursts)..<(count * (burst + 1) / bursts) {
                var packet = Data(repeating: UInt8(truncatingIfNeeded: index), count: 1200)
                var serial = UInt64(index).littleEndian
                var sentAt = DispatchTime.now().uptimeNanoseconds.littleEndian
                withUnsafeBytes(of: &serial) { packet.replaceSubrange(0..<8, with: $0) }
                withUnsafeBytes(of: &sentAt) { packet.replaceSubrange(8..<16, with: $0) }
                let sent = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard sent == packet.count else { throw MoonlightError(.unsupportedOperation, message: "Video sender failed") }
            }
        }
    }
    private static func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double { values[min(values.count - 1, Int(Double(values.count - 1) * fraction))] }
}
