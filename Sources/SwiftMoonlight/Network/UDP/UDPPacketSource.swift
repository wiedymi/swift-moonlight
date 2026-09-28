import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public actor UDPPacketSource: MediaPacketSource {
    private let fileDescriptor: Int32
    private var closed = false
    private let port: UInt16
    private var receiveBuffer = [UInt8](repeating: 0, count: 65_536)

    public init(bindHost: String = "127.0.0.1", port: UInt16 = 0) throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create UDP socket")
        }

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let inetResult = bindHost.withCString { cs in
            inet_pton(AF_INET, cs, &address.sin_addr)
        }
        guard inetResult == 1 else {
            close(socketFD)
            throw MoonlightError(.unsupportedOperation, message: "Invalid UDP bind host")
        }

        var bindAddress = address
        let bindResult = withUnsafePointer(to: &bindAddress) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw MoonlightError(.unsupportedOperation, message: "Failed to bind UDP socket")
        }

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        var localAddress = sockaddr_in()
        var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &localAddress) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &localLength)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            throw MoonlightError(.unsupportedOperation, message: "Failed to query UDP socket name")
        }

        fileDescriptor = socketFD
        self.port = UInt16(bigEndian: localAddress.sin_port)
    }

    public func localPort() -> UInt16 {
        port
    }

    public func receivePacket() async throws -> Data? {
        while !closed {
            let bytesRead = recv(fileDescriptor, &receiveBuffer, receiveBuffer.count, 0)
            if bytesRead > 0 {
                return Data(receiveBuffer.prefix(Int(bytesRead)))
            }

            if bytesRead == 0 {
                closed = true
                break
            }

            let err = errno
            if err == EWOULDBLOCK || err == EAGAIN {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }

            closed = true
            throw MoonlightError(.unsupportedOperation, message: "UDP receive failed with errno \(err)")
        }

        return nil
    }

    public func stop() {
        guard !closed else {
            return
        }
        closed = true
        close(fileDescriptor)
    }
}
