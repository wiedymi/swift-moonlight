import Foundation
import Testing
@testable import SwiftMoonlight
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Test
func connectedUDPSocketSendsAndReceivesLoopbackPacketsViaHostname() async throws {
    let listener = try LoopbackUDPServer()
    defer {
        Task { await listener.close() }
    }

    let listenerPort = try await listener.localPort()
    let socket = try ConnectedUDPSocket(remoteHost: "localhost", remotePort: listenerPort)
    defer {
        Task { await socket.close() }
    }

    try await socket.send(Data([0xAA, 0xBB]))
    let receivedByListener = try await listener.receivePacket()
    #expect(receivedByListener == Data([0xAA, 0xBB]))

    let localPort = try await socket.localPort()
    try await listener.send(Data([0xCC, 0xDD]), to: localPort)
    let receivedBySocket = try await socket.receivePacket()
    #expect(receivedBySocket == Data([0xCC, 0xDD]))
}

@Test
func boundUDPSocketCloseWakesIdleReceiver() async throws {
    let socket = try BoundUDPSocket(remoteHost: "127.0.0.1", remotePort: 47_998)
    let receiver = Task { try await socket.receivePacket() }

    try await Task.sleep(for: .milliseconds(20))
    await socket.close()

    #expect(try await receiver.value == nil)
}

@Test
func boundUDPSocketCancelWakesIdleReceiver() async throws {
    let socket = try BoundUDPSocket(remoteHost: "127.0.0.1", remotePort: 47_998)
    let receiver = Task { try await socket.receivePacket() }

    try await Task.sleep(for: .milliseconds(20))
    receiver.cancel()

    #expect(try await receiver.value == nil)
    await socket.close()
}

@Test
func boundUDPSocketReceivesAfterRepeatedIdleWaits() async throws {
    let sender = try LoopbackUDPServer()
    let socket = try BoundUDPSocket(remoteHost: "127.0.0.1", remotePort: try await sender.localPort())
    let localPort = try await socket.localPort()

    for value in UInt8(0)..<UInt8(10) {
        let receiver = Task { try await socket.receivePacket() }
        try await Task.sleep(for: .milliseconds(2))
        try await sender.send(Data([value]), to: localPort)
        #expect(try await receiver.value == Data([value]))
    }

    await socket.close()
    await sender.close()
}

@Test
func channelSocketFactoryCreatesLoopbackReadySockets() async throws {
    let controlListener = try LoopbackUDPServer()
    let inputListener = try LoopbackUDPServer()
    let videoListener = try LoopbackUDPServer()
    let audioListener = try LoopbackUDPServer()
    defer {
        Task {
            await controlListener.close()
            await inputListener.close()
            await videoListener.close()
            await audioListener.close()
        }
    }

    let controlPort = try await controlListener.localPort()
    let inputPort = try await inputListener.localPort()
    let videoPort = try await videoListener.localPort()
    let audioPort = try await audioListener.localPort()

    let host = MoonlightHost(
        id: HostID(),
        name: "Loopback",
        endpoint: .init(address: "127.0.0.1", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let negotiated = NegotiatedSession(
        hostID: host.id,
        appID: "desktop",
        rtspSessionURL: "rtsp://127.0.0.1:47998",
        channels: [
            EstablishedChannel(descriptor: .init(kind: .control, port: controlPort)),
            EstablishedChannel(descriptor: .init(kind: .input, port: inputPort)),
            EstablishedChannel(descriptor: .init(kind: .video, port: videoPort)),
            EstablishedChannel(descriptor: .init(kind: .audio, port: audioPort))
        ]
    )

    let sockets = try ChannelSocketFactory().makeSockets(for: host, negotiatedSession: negotiated)

    #expect(sockets.controlTransport != nil)
    #expect(sockets.inputTransport != nil)
    #expect(sockets.videoSource != nil)
    #expect(sockets.audioSource != nil)

    try await sockets.controlTransport?.send(packet: Data([0x01, 0x02]), channelID: 1, reliable: true)
    try await sockets.inputTransport?.send(Data([0x03, 0x04]), channelID: ControlChannelID.mouse, reliable: true)

    let controlReceived = try await controlListener.receivePacket()
    let inputReceived = try await inputListener.receivePacket()
    #expect(controlReceived == Data([0x01, 0x02]))
    #expect(inputReceived == Data([0x03, 0x04]))

    let videoLocalPort = try await sockets.videoSource?.localPort()
    let audioLocalPort = try await sockets.audioSource?.localPort()
    #expect(videoLocalPort != nil)
    #expect(audioLocalPort != nil)

    try await videoListener.send(Data([0x05, 0x06]), to: try #require(videoLocalPort))
    try await audioListener.send(Data([0x07, 0x08]), to: try #require(audioLocalPort))

    let videoReceived = try await sockets.videoSource?.receivePacket()
    let audioReceived = try await sockets.audioSource?.receivePacket()
    #expect(videoReceived == Data([0x05, 0x06]))
    #expect(audioReceived == Data([0x07, 0x08]))
}

private actor LoopbackUDPServer {
    private let socketFD: Int32
    private var closed = false

    init() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw SendError.socketCreationFailed
        }
        self.socketFD = socketFD

        var reuseAddress: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        let inetResult = "127.0.0.1".withCString { cs in
            inet_pton(AF_INET, cs, &address.sin_addr)
        }
        guard inetResult == 1 else {
            Darwin.close(socketFD)
            throw SendError.invalidAddress
        }

        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw SendError.bindFailed
        }
    }

    deinit {
        if !closed {
            Darwin.close(socketFD)
        }
    }

    func localPort() throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let result = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(socketFD, sockPtr, &length)
            }
        }
        guard result == 0 else {
            throw SendError.portQueryFailed
        }
        return UInt16(bigEndian: address.sin_port)
    }

    func receivePacket() async throws -> Data? {
        while !Task.isCancelled {
            var buffer = [UInt8](repeating: 0, count: 65535)
            let received = recv(socketFD, &buffer, buffer.count, 0)
            if received > 0 {
                return Data(buffer.prefix(received))
            }
            if received == 0 {
                return nil
            }

            switch errno {
            case EWOULDBLOCK, EAGAIN:
                try await Task.sleep(for: .milliseconds(10))
            default:
                throw SendError.receiveFailed
            }
        }
        return nil
    }

    func send(_ payload: Data, to port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
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

    func close() {
        guard !closed else {
            return
        }
        closed = true
        Darwin.close(socketFD)
    }
}

private enum SendError: Error {
    case socketCreationFailed
    case invalidAddress
    case bindFailed
    case portQueryFailed
    case receiveFailed
    case sendFailed
}
