import Darwin
import Foundation

enum UDPSocketAddressing {
    static func resolveIPv4Address(_ host: String) throws -> in_addr {
        if host == "0.0.0.0" {
            return in_addr(s_addr: INADDR_ANY)
        }

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let result else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to resolve UDP host \(host)")
        }
        defer { freeaddrinfo(result) }

        guard let sockaddr = result.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) else {
            throw MoonlightError(.unsupportedOperation, message: "Resolved UDP host \(host) did not produce an IPv4 address")
        }

        return sockaddr.sin_addr
    }

    static func resolveBindIPv4Address(bindHost: String, remoteHost: String, remotePort: UInt16) throws -> in_addr {
        if bindHost != "0.0.0.0" {
            return try resolveIPv4Address(bindHost)
        }

        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to create UDP socket for route resolution")
        }
        defer { Darwin.close(socketFD) }

        var remoteAddress = sockaddr_in()
        remoteAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        remoteAddress.sin_family = sa_family_t(AF_INET)
        remoteAddress.sin_port = remotePort.bigEndian
        remoteAddress.sin_addr = try resolveIPv4Address(remoteHost)

        let connectResult = withUnsafePointer(to: &remoteAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.connect(socketFD, pointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard connectResult == 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to resolve UDP local route to \(remoteHost):\(remotePort)")
        }

        var localAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &localAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(socketFD, pointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to query UDP local route to \(remoteHost):\(remotePort)")
        }

        return localAddress.sin_addr
    }
}
