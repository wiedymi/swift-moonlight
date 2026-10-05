import Darwin
import Dispatch
import Foundation

public actor BoundUDPSocket {
    private let socketFD: Int32
    private let remoteHost: String
    private let remotePort: UInt16
    private let remoteAddress: sockaddr_in
    private let readSource: DispatchSourceRead
    private var isClosed = false
    private var isReadSourceActive = false
    private var receiveBuffer = [UInt8](repeating: 0, count: 65_535)
    private var readinessWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

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

        // Match moonlight-common-c's RTP_RECV_PACKETS_BUFFERED (2048 * ~1500 bytes).
        // The default macOS UDP receive buffer is too small for video streams,
        // causing packet loss between socket creation and receive loop start.
        var rcvBufSize: Int32 = 2048 * 1500
        while setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &rcvBufSize, socklen_t(MemoryLayout<Int32>.size)) != 0,
              rcvBufSize > 192_000 {
            rcvBufSize /= 2
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
        localAddress.sin_addr = in_addr(s_addr: INADDR_ANY)

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
        do {
            remoteAddress.sin_addr = try UDPSocketAddressing.resolveIPv4Address(remoteHost)
        } catch {
            Darwin.close(socketFD)
            throw error
        }
        self.remoteAddress = remoteAddress
        let readSource = DispatchSource.makeReadSource(fileDescriptor: socketFD)
        self.readSource = readSource
        readSource.setEventHandler { [weak self] in
            Task { await self?.signalReadable() }
        }
    }

    deinit {
        readSource.cancel()
        if !isReadSourceActive {
            readSource.resume()
        }
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

        var remoteAddress = self.remoteAddress
        let sent = packet.withUnsafeBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return withUnsafePointer(to: &remoteAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    Darwin.sendto(socketFD, baseAddress, packet.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
        }

        guard sent == packet.count else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to send UDP packet to \(remoteHost):\(remotePort)")
        }
    }

    public func receivePacket() async throws -> Data? {
        guard !isClosed else {
            return nil
        }

        while !isClosed && !Task.isCancelled {
            let received = recv(socketFD, &receiveBuffer, receiveBuffer.count, 0)
            if received > 0 {
                return Data(receiveBuffer.prefix(received))
            }
            if received == 0 { continue } // An empty datagram is not a socket close.

            switch errno {
            case EINTR:
                continue
            case EWOULDBLOCK, EAGAIN:
                await waitForReadiness()
                continue
            case ECONNREFUSED, ECONNRESET, ENETUNREACH, EHOSTUNREACH:
                try await Task.sleep(for: .milliseconds(50))
                continue
            default:
                throw MoonlightError(.unsupportedOperation, message: "Failed to receive UDP packet")
            }
        }

        return nil
    }

    /// Drain at most 64 datagrams without waiting for a full batch.
    public func receivePackets(maximumCount: Int) async throws -> [Data] {
        let limit = min(64, max(0, maximumCount))
        guard limit > 0, let first = try await receivePacket() else { return [] }
        var packets = [first]
        for _ in 1..<limit {
            guard !isClosed && !Task.isCancelled else { break }
            let received = recv(socketFD, &receiveBuffer, receiveBuffer.count, 0)
            if received < 0 { break } // The next read handles readiness or the error.
            if received > 0 { packets.append(Data(receiveBuffer.prefix(received))) }
        }
        return packets
    }

    /// Kernel-selected capacity, in bytes. No host or packet data is included.
    public func receiveBufferCapacity() throws -> Int {
        guard !isClosed else { return 0 }
        var capacity: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &capacity, &length) == 0 else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to query UDP receive capacity")
        }
        return max(0, Int(capacity))
    }

    public func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        readSource.cancel()
        if !isReadSourceActive {
            readSource.resume()
            isReadSourceActive = true
        }
        Darwin.close(socketFD)
        wakeWaiters()
    }

    private func waitForReadiness() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await self.suspendUntilReadable(id)
        } onCancel: {
            Task { await self.resumeWaiter(id) }
        }
    }

    // An explicit actor call preserves isolation in optimized builds.
    private func suspendUntilReadable(_ id: UUID) async {
        await withCheckedContinuation(isolation: self) { continuation in
            if isClosed || Task.isCancelled {
                continuation.resume()
            } else {
                readinessWaiters[id] = continuation
                if !isReadSourceActive {
                    isReadSourceActive = true
                    readSource.resume()
                }
            }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        readinessWaiters.removeValue(forKey: id)?.resume()
    }

    private func signalReadable() {
        guard !isClosed, isReadSourceActive else { return }
        readSource.suspend()
        isReadSourceActive = false
        wakeWaiters()
    }

    private func wakeWaiters() {
        let waiters = readinessWaiters
        readinessWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters.values {
            waiter.resume()
        }
    }
}
