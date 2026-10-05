import Darwin
import Foundation
import Testing
@testable import SwiftENet
@testable import SwiftMoonlight

@Test func enetSessionRetriesAndReceivesWithoutApplicationPollingAndClosesBothAdapters() async throws {
    let server = try ENetTestListener(host: "::1")
    let host = Task {
        let connect = try await server.receive()
        let command = try #require(try Datagram.decode(connect.data).commands.first)
        guard case .connect(var parameters, let data) = command.body else { throw ClientError.invalidConnect }
        #expect(data == 0x1234)
        parameters.peerID = 9; parameters.incomingSession = 1; parameters.outgoingSession = 2
        try server.send(Datagram(peerID: 0, sessionID: 1, sentTime: 0,
                                     commands: [.init(sequence: 1, body: .verify(parameters))]).encoded(), to: connect.address)
        var gotStart = false
        var firstStart: Command?
        while !gotStart {
            let packet = try await server.receive()
            let datagram = try Datagram.decode(packet.data)
            #expect(datagram.peerID == 9)
            #expect(datagram.sessionID == 2)
            for command in datagram.commands {
                if case .reliable(let payload) = command.body, payload == Data([7, 3, 0]) {
                    if let firstStart {
                        // The lost ACK must cause an identical retry even when
                        // the application has no pending reader or sender.
                        #expect(command == firstStart)
                        gotStart = true
                    } else {
                        firstStart = command
                        continue
                    }
                }
                if command.requestsAcknowledgement, let time = datagram.sentTime {
                    try server.send(Datagram(peerID: 0, sessionID: 1, sentTime: nil,
                                                 commands: [.init(channel: command.channel, body: .acknowledge(sequence: command.sequence, time: time))]).encoded(), to: packet.address)
                }
            }
        }
        try server.send(Datagram(peerID: 0, sessionID: 1, sentTime: 1,
                                     commands: [.init(channel: 1, sequence: 1, body: .reliable(Data([9, 8, 7]))) ]).encoded(), to: connect.address)
    }
    let session = try await ENetControlSession(remoteHost: "::1", remotePort: server.port, connectData: 0x1234, controlEncryption: nil)
    let control = ENetControlChannelTransport(session: session)
    let input = ENetInputPacketTransport(session: session)
    try await host.value
    #expect(try await control.receivePacket() == Data([9, 8, 7]))
    #expect(await control.snapshotControlTransportMetrics().isConnected)
    for _ in 0..<10 {
        let cancelled = Task { try await control.receivePacket() }
        try await Task.sleep(for: .milliseconds(1))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled read returned normally")
        } catch { #expect(error is CancellationError) }
    }
    #expect(await control.snapshotControlTransportMetrics().isConnected)
    let waiting = Task { try await control.receivePacket() }
    await input.close()
    #expect(try await waiting.value == nil)
    await control.close()
    #expect(!(await control.snapshotControlTransportMetrics().isConnected))
}

// Nonblocking test socket. Every receive has a finite deadline. The server is
// retained by each task that uses it, so descriptor teardown cannot race I/O.
private final class ENetTestListener: Sendable {
    struct Packet: Sendable { let data: Data; let address: Data }
    let port: UInt16
    private let descriptor: Int32

    init(host: String) throws {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "0", &hints, &result) == 0, let result else { throw ClientError.invalidConnect }
        defer { freeaddrinfo(result) }
        let fd = Darwin.socket(result.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ClientError.invalidConnect }
        guard Darwin.bind(fd, result.pointee.ai_addr, result.pointee.ai_addrlen) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw ClientError.invalidConnect }
        var address = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let query = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard query == 0 else { Darwin.close(fd); throw ClientError.invalidConnect }
        port = withUnsafePointer(to: address) {
            if Int32(address.ss_family) == AF_INET6 {
                return $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            return $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }
    func receive() async throws -> Packet {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var bytes = [UInt8](repeating: 0, count: 65535)
            var address = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &bytes, bytes.count, 0, $0, &length) }
            }
            if count >= 0 {
                let addressBytes = withUnsafeBytes(of: address) { Data($0.prefix(Int(length))) }
                return Packet(data: Data(bytes.prefix(count)), address: addressBytes)
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw ClientError.invalidPacket }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ClientError.timedOut
    }
    func send(_ packet: Data, to address: Data) throws {
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: address) }
        let count = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(address.count)) }
            }
        }
        guard count == packet.count else { throw ClientError.invalidPacket }
    }
}
