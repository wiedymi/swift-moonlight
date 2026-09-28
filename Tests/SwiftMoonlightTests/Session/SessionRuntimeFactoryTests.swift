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
func sessionRuntimeFactoryBuildsLoopbackRuntimeAndAttachesInputSender() async throws {
    let controlServer = try LoopbackRuntimeUDPServer()
    let inputServer = try LoopbackRuntimeUDPServer()
    let videoServer = try LoopbackRuntimeUDPServer()
    let audioServer = try LoopbackRuntimeUDPServer()
    defer {
        Task {
            await controlServer.close()
            await inputServer.close()
            await videoServer.close()
            await audioServer.close()
        }
    }

    let host = MoonlightHost(
        id: HostID(),
        name: "Loopback Host",
        endpoint: .init(address: "127.0.0.1", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let negotiated = NegotiatedSession(
        hostID: host.id,
        appID: "desktop",
        rtspSessionURL: "rtsp://127.0.0.1:47998",
        videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)),
        audioFormat: .init(sampleRate: 48_000, channelCount: 2),
        channels: [
            EstablishedChannel(descriptor: .init(kind: .control, port: try await controlServer.localPort())),
            EstablishedChannel(descriptor: .init(kind: .input, port: try await inputServer.localPort())),
            EstablishedChannel(descriptor: .init(
                kind: .video,
                port: try await videoServer.localPort(),
                metadata: ["pingPayload": "1234567890abcdef"]
            )),
            EstablishedChannel(descriptor: .init(
                kind: .audio,
                port: try await audioServer.localPort(),
                metadata: ["pingPayload": "fedcba0987654321"]
            ))
        ]
    )

    let session = MoonlightSession(negotiatedSession: negotiated)
    try await session.attachVideoDecoder(RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 33, dimensions: CGSize(width: 640, height: 360), bytes: Data([0x01]))
    ]]))
    let renderer = RecordingRenderer()
    try await session.attachRenderer(renderer)
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x10, 0x20]))
    ]))
    let sink = RecordingAudioSink()
    try await session.attachAudioSink(sink)

    let prepared = try await SessionRuntimeFactory(logger: TestLogger()).makeRuntime(host: host, session: session)
    await prepared.runtime.start()

    let videoKeepalive = try await videoServer.receivePacket()
    let audioKeepalive = try await audioServer.receivePacket()
    #expect(videoKeepalive == Data("1234567890abcdef".utf8) + Data([0, 0, 0, 1]))
    #expect(audioKeepalive == Data("fedcba0987654321".utf8) + Data([0, 0, 0, 1]))

    try await session.send(.keyboard(.keyDown(.space)))
    let inputPacket = try await inputServer.receivePacket()
    let expectedInputPacket = try #require(Data(hexString: "0000000A03000000002000000000"))
    #expect(inputPacket == expectedInputPacket)

    try await session.send(.mouse(.absoluteMove(x: 0.5, y: 0.25)))
    let absoluteInputPacket = try await inputServer.receivePacket()
    let expectedAbsoluteInputPacket = try #require(Data(hexString: "0000000C050000000140005A0000027F0167"))
    #expect(absoluteInputPacket == expectedAbsoluteInputPacket)

    let videoPort = try await prepared.sockets.videoSource?.localPort()
    let audioPort = try await prepared.sockets.audioSource?.localPort()
    let controlPort = try await prepared.sockets.controlTransport?.localPort()
    try await videoServer.send(makeFactoryVideoPacket(
        sequenceNumber: 1,
        timestamp: 33,
        streamPacketIndex: 1,
        frameIndex: 1,
        flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
        payload: Data([0,0,0,0,0,0,0,0, 0x99])
    ), to: try #require(videoPort))
    try await audioServer.send(
        makeFactoryAudioPacket(sequenceNumber: 1, timestamp: 960, payload: Data([0xA1, 0xB2])),
        to: try #require(audioPort)
    )
    try await controlServer.send(try #require(Data(hexString: "0B0100000000010022114433")), to: try #require(controlPort))

    let events = await session.events
    var iterator = events.makeAsyncIterator()
    var feedbackSeen = false
    var attempts = 0
    while !feedbackSeen && attempts < 20 {
        if let event = await iterator.next(),
           case .controllerFeedback(let feedback) = event {
            #expect(feedback.controllerID == 1)
            feedbackSeen = true
        }
        attempts += 1
        try await Task.sleep(for: .milliseconds(5))
    }

    let (rendered, played) = await waitForMediaOutput(renderer: renderer, sink: sink)
    #expect(feedbackSeen)
    #expect(rendered.count >= 1)
    #expect(played.count >= 1)

    await prepared.stop()

    let videoAfterStop = try await prepared.sockets.videoSource?.receivePacket()
    let audioAfterStop = try await prepared.sockets.audioSource?.receivePacket()
    #expect(videoAfterStop == nil)
    #expect(audioAfterStop == nil)
}

@Test
func sessionRuntimeFactoryAutoConfiguresEncryptedMediaFromNegotiatedSession() async throws {
    let videoServer = try LoopbackRuntimeUDPServer()
    let audioServer = try LoopbackRuntimeUDPServer()
    defer {
        Task {
            await videoServer.close()
            await audioServer.close()
        }
    }

    let host = MoonlightHost(
        id: HostID(),
        name: "Encrypted Host",
        endpoint: .init(address: "127.0.0.1", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let secrets = RemoteInputSecrets(
        key: try Data(hexString: "00112233445566778899aabbccddeeff"),
        keyID: 42
    )
    let negotiated = NegotiatedSession(
        hostID: host.id,
        appID: "desktop",
        rtspSessionURL: "rtsp://127.0.0.1:47998",
        videoFormat: .init(codec: .hevc, dimensions: CGSize(width: 640, height: 360)),
        audioFormat: .init(sampleRate: 48_000, channelCount: 2),
        remoteInputSecrets: secrets,
        encryptionFeatures: [.video, .audio],
        channels: [
            EstablishedChannel(descriptor: .init(kind: .video, port: try await videoServer.localPort())),
            EstablishedChannel(descriptor: .init(kind: .audio, port: try await audioServer.localPort()))
        ]
    )

    let session = MoonlightSession(negotiatedSession: negotiated)
    try await session.attachVideoDecoder(RecordingVideoDecoder(decodeOutputs: [[
        DecodedVideoFrame(timestamp: 33, dimensions: CGSize(width: 640, height: 360), bytes: Data([0x01]))
    ]]))
    let renderer = RecordingRenderer()
    try await session.attachRenderer(renderer)
    try await session.attachAudioDecoder(RecordingAudioDecoder(outputs: [
        PCMBuffer(sampleRate: 48_000, channelCount: 2, frameCount: 480, bytesPerFrame: 4, data: Data([0x10, 0x20]))
    ]))
    let sink = RecordingAudioSink()
    try await session.attachAudioSink(sink)

    let prepared = try await SessionRuntimeFactory(logger: TestLogger()).makeRuntime(host: host, session: session)
    await prepared.runtime.start()

    let encryptedVideo = try MediaCrypto.encryptVideoPacket(
        makeFactoryVideoPacket(
            sequenceNumber: 1,
            timestamp: 33,
            streamPacketIndex: 1,
            frameIndex: 1,
            flags: VideoPacketHeader.startOfFrameFlag | VideoPacketHeader.endOfFrameFlag,
            payload: Data([0,0,0,0,0,0,0,0, 0x99])
        ),
        frameNumber: 1,
        context: VideoEncryptionContext(key: secrets.key),
        iv: Data([0,1,2,3,4,5,6,7,8,9,10,11])
    )
    let plainAudio = makeFactoryAudioPacket(sequenceNumber: 1, timestamp: 960, payload: Data([0xA1, 0xB2]))
    let encryptedAudio = try MediaCrypto.encryptAudioPacket(
        rtpHeader: Data(plainAudio.prefix(RTPHeader.fixedSize)),
        payload: Data(plainAudio.dropFirst(RTPHeader.fixedSize)),
        context: AudioEncryptionContext(key: secrets.key, avRiKeyID: secrets.keyID),
        sequenceNumber: 1
    )

    let videoPort = try await prepared.sockets.videoSource?.localPort()
    let audioPort = try await prepared.sockets.audioSource?.localPort()
    try await videoServer.send(encryptedVideo, to: try #require(videoPort))
    try await audioServer.send(encryptedAudio, to: try #require(audioPort))

    let (rendered, played) = await waitForMediaOutput(renderer: renderer, sink: sink)
    #expect(rendered.count >= 1)
    #expect(played.count >= 1)

    await prepared.stop()
}

private func waitForMediaOutput(
    renderer: RecordingRenderer,
    sink: RecordingAudioSink
) async -> ([DecodedVideoFrame], [PCMBuffer]) {
    var rendered = await renderer.recordedFrames()
    var played = await sink.recordedBuffers()
    for _ in 0..<200 {
        if rendered.count >= 1, played.count >= 1 {
            return (rendered, played)
        }
        try? await Task.sleep(for: .milliseconds(5))
        rendered = await renderer.recordedFrames()
        played = await sink.recordedBuffers()
    }
    return (rendered, played)
}

private actor LoopbackRuntimeUDPServer {
    private let socketFD: Int32
    private var closed = false

    init() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw RuntimeSocketError.socketCreationFailed
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
            throw RuntimeSocketError.invalidAddress
        }

        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw RuntimeSocketError.bindFailed
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
            throw RuntimeSocketError.portQueryFailed
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
                throw RuntimeSocketError.receiveFailed
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
            throw RuntimeSocketError.invalidAddress
        }

        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(socketFD, bytes.baseAddress, bytes.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else {
            throw RuntimeSocketError.sendFailed
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

private enum RuntimeSocketError: Error {
    case socketCreationFailed
    case invalidAddress
    case bindFailed
    case portQueryFailed
    case receiveFailed
    case sendFailed
}

private func makeFactoryVideoPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    streamPacketIndex: UInt32,
    frameIndex: UInt32,
    flags: UInt8,
    payload: Data
) -> Data {
    var data = Data()
    data.append(0x80)
    data.append(0x60)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,1])
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: streamPacketIndex),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 8),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 16),
        UInt8(truncatingIfNeeded: streamPacketIndex >> 24),
        UInt8(truncatingIfNeeded: frameIndex),
        UInt8(truncatingIfNeeded: frameIndex >> 8),
        UInt8(truncatingIfNeeded: frameIndex >> 16),
        UInt8(truncatingIfNeeded: frameIndex >> 24),
        flags, 0, 0, 0, 0, 0, 0, 0
    ])
    data.append(payload)
    return data
}

private func makeFactoryAudioPacket(
    sequenceNumber: UInt16,
    timestamp: UInt32,
    payload: Data
) -> Data {
    var data = Data()
    data.append(0x80)
    data.append(0x61)
    data.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
    data.append(UInt8(truncatingIfNeeded: sequenceNumber))
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: timestamp >> 24),
        UInt8(truncatingIfNeeded: timestamp >> 16),
        UInt8(truncatingIfNeeded: timestamp >> 8),
        UInt8(truncatingIfNeeded: timestamp)
    ])
    data.append(contentsOf: [0,0,0,2])
    data.append(payload)
    return data
}
