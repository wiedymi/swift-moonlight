import Darwin
import Foundation

public actor ConnectedUDPSocket {
    private let socketFD: Int32
    private let remoteHost: String
    private let remotePort: UInt16
    private var isClosed = false
    private var receiveBuffer = [UInt8](repeating: 0, count: 65_535)

    public init(
        remoteHost: String,
        remotePort: UInt16,
        bindHost: String = "0.0.0.0",
        localPort: UInt16 = 0
    ) throws {
        self.remoteHost = remoteHost
        self.remotePort = remotePort

        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create UDP socket")
        }

        self.socketFD = socketFD

        var reuseAddress: Int32 = 1
        if setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            Darwin.close(socketFD)
            throw MoonlightError(.unsupportedOperation, message: "Failed to configure UDP socket reuse")
        }

        let flags = fcntl(socketFD, F_GETFL, 0)
        if flags == -1 || fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == -1 {
            Darwin.close(socketFD)
            throw MoonlightError(.unsupportedOperation, message: "Failed to configure nonblocking UDP socket")
        }

        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = localPort.bigEndian

        localAddress.sin_addr = try UDPSocketAddressing.resolveBindIPv4Address(
            bindHost: bindHost,
            remoteHost: remoteHost,
            remotePort: remotePort
        )

        let bindResult = withUnsafePointer(to: &localAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(socketFD, pointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw MoonlightError(.unsupportedOperation, message: "Failed to bind UDP socket to \(bindHost):\(localPort)")
        }

        var remoteAddress = sockaddr_in()
        remoteAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        remoteAddress.sin_family = sa_family_t(AF_INET)
        remoteAddress.sin_port = remotePort.bigEndian
        remoteAddress.sin_addr = try UDPSocketAddressing.resolveIPv4Address(remoteHost)

        let connectResult = withUnsafePointer(to: &remoteAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.connect(socketFD, pointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard connectResult == 0 else {
            Darwin.close(socketFD)
            throw MoonlightError(.unsupportedOperation, message: "Failed to connect UDP socket to \(remoteHost):\(remotePort)")
        }
    }

    deinit {
        if !isClosed {
            Darwin.close(socketFD)
        }
    }

    public func localPort() throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(socketFD, pointer, &length)
            }
        }

        guard result == 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to query UDP socket local port")
        }

        return UInt16(bigEndian: address.sin_port)
    }

    public func send(_ packet: Data) throws {
        guard !isClosed else {
            throw MoonlightError(.invalidStateTransition, message: "Cannot send after socket close")
        }

        let sent = packet.withUnsafeBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return Darwin.send(socketFD, baseAddress, packet.count, 0)
        }

        guard sent == packet.count else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to send UDP packet to \(remoteHost):\(remotePort)")
        }
    }

    public func receivePacket() async throws -> Data? {
        guard !isClosed else {
            return nil
        }

        while !Task.isCancelled {
            let received = recv(socketFD, &receiveBuffer, receiveBuffer.count, 0)
            if received > 0 {
                return Data(receiveBuffer.prefix(received))
            }
            if received == 0 {
                return nil
            }

            switch errno {
            case EWOULDBLOCK, EAGAIN:
                try await Task.sleep(for: .milliseconds(10))
                continue
            default:
                throw MoonlightError(.unsupportedOperation, message: "Failed to receive UDP packet")
            }
        }

        return nil
    }

    public func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        Darwin.close(socketFD)
    }
}
