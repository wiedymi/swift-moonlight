import CoreGraphics
import Foundation
import Testing
@testable import SwiftMoonlight
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Test
func udpPacketSourceReceivesLoopbackDatagram() async throws {
    let source = try UDPPacketSource(port: 0)
    defer {
        Task { await source.stop() }
    }

    let port = await source.localPort()
    try sendUDPDatagram(Data([0xDE, 0xAD, 0xBE, 0xEF]), to: port)

    let received = try await source.receivePacket()

    #expect(received == Data([0xDE, 0xAD, 0xBE, 0xEF]))
}

private func sendUDPDatagram(_ payload: Data, to port: UInt16) throws {
    let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard socketFD >= 0 else {
        throw SendError.socketCreationFailed
    }
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    let inetResult = "127.0.0.1".withCString { cs in
        inet_pton(AF_INET, cs, &address.sin_addr)
    }
    guard inetResult == 1 else {
        throw SendError.invalidAddress
    }

    let sent = payload.withUnsafeBytes { bytes in
        withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(socketFD, bytes.baseAddress, bytes.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard sent == payload.count else {
        throw SendError.sendFailed
    }
}

private enum SendError: Error {
    case socketCreationFailed
    case invalidAddress
    case sendFailed
}

@Test func boundSocketBatchIsBoundedAndPreservesPacketOrder() async throws {
    let socket = try BoundUDPSocket(remoteHost: "127.0.0.1", remotePort: 9)
    let source = UDPChannelPacketSource(socket: socket)
    let port = try await source.localPort()
    try sendUDPDatagram(Data(), to: port)
    for index in 0..<80 { try sendUDPDatagram(Data([UInt8(index)]), to: port) }
    let first = try await source.receivePackets(maximumCount: 500)
    let second = try await source.receivePackets(maximumCount: 64)
    #expect(first.count == 64)
    #expect(second.count == 16)
    #expect(first + second == (0..<80).map { Data([UInt8($0)]) })
    #expect(try await socket.receiveBufferCapacity() > 0)
    await source.close()
    #expect(try await source.receivePackets(maximumCount: 64).isEmpty)
}
