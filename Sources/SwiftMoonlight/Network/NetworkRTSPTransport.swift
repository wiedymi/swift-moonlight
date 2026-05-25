import Foundation
#if canImport(Network)
import Network

public actor NetworkRTSPTransport: RTSPTransport {
    private var clients: [String: RTSPSessionClient] = [:]
    private let parser = RTSPMessageParser()

    public init() {}

    public func transact(sessionURL: String, request: RTSPRequest, encryptionKey: Data?) async throws -> RTSPResponse {
        let client = try await makeClient(for: sessionURL, encryptionKey: encryptionKey)
        let responseData = try await client.transact(request.serialized())
        let message = try parser.parse(responseData)
        guard case let .response(response) = message else {
            throw MoonlightError(.invalidLaunchResponse, message: "Expected RTSP response message")
        }
        return response
    }

    public func close(sessionURL: String) async {
        guard let client = clients.removeValue(forKey: sessionURL) else {
            return
        }
        await client.close()
    }

    public func closeAll() async {
        let currentClients = clients.values
        clients.removeAll()
        for client in currentClients {
            await client.close()
        }
    }

    private func makeClient(for sessionURL: String, encryptionKey: Data?) async throws -> RTSPSessionClient {
        if let existing = clients[sessionURL] {
            try await existing.updateEncryptionKey(encryptionKey)
            return existing
        }

        guard let url = URL(string: sessionURL),
              let host = url.host(percentEncoded: false) ?? url.host,
              let port = url.port
        else {
            throw MoonlightError(.unsupportedOperation, message: "Invalid RTSP session URL: \(sessionURL)")
        }

        let client = RTSPSessionClient(
            host: host,
            port: UInt16(port),
            encryptionKey: encryptionKey,
            isEncryptedSession: url.scheme?.caseInsensitiveCompare("rtspenc") == .orderedSame
        )
        clients[sessionURL] = client
        return client
    }
}

actor RTSPSessionClient {
    private let host: String
    private let port: UInt16
    private let crypto = RTSPMessageCrypto()
    private let isEncryptedSession: Bool
    private var encryptionKey: Data?
    private var sendSequenceNumber: UInt32 = 0

    init(host: String, port: UInt16, encryptionKey: Data?, isEncryptedSession: Bool) {
        self.host = host
        self.port = port
        self.encryptionKey = encryptionKey
        self.isEncryptedSession = isEncryptedSession
    }

    func updateEncryptionKey(_ encryptionKey: Data?) throws {
        if self.encryptionKey != encryptionKey {
            sendSequenceNumber = 0
        }
        self.encryptionKey = encryptionKey
    }

    func transact(_ data: Data) async throws -> Data {
        let connection = try await connect()
        var receiveBuffer = Data()
        do {
            let payload = try outboundPayload(from: data)
            try await send(payload, over: connection)

            while true {
                if let message = try extractMessageFromBuffer(&receiveBuffer) {
                    connection.cancel()
                    return message
                }

                let chunk = try await receiveChunk(over: connection)
                if let chunk, !chunk.isEmpty {
                    receiveBuffer.append(chunk)
                    continue
                }

                if let message = try extractMessageFromBuffer(&receiveBuffer) {
                    connection.cancel()
                    return message
                }

                throw MoonlightError(.unsupportedOperation, message: "RTSP connection closed before a full response was received")
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    func close() {
    }

    private func connect() async throws -> NWConnection {
        let maxRetries = 20
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await startConnectionAttempt()
            } catch {
                lastError = error
                guard shouldRetryConnection(error), attempt < maxRetries else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        throw lastError ?? MoonlightError(.unsupportedOperation, message: "RTSP connection failed")
    }

    private func startConnectionAttempt() async throws -> NWConnection {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: port)
        let newConnection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            let gate = ContinuationGate()
            newConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.tryOpen() else { return }
                    continuation.resume(returning: newConnection)
                case .failed(let error):
                    guard gate.tryOpen() else { return }
                    continuation.resume(throwing: MoonlightError(.unsupportedOperation, message: "RTSP connection failed: \(error)"))
                case .cancelled:
                    guard gate.tryOpen() else { return }
                    continuation.resume(throwing: MoonlightError(.unsupportedOperation, message: "RTSP connection was cancelled"))
                default:
                    break
                }
            }
            newConnection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func shouldRetryConnection(_ error: Error) -> Bool {
        guard let moonlightError = error as? MoonlightError else {
            return false
        }
        return moonlightError.message.contains("ECONNREFUSED")
            || moonlightError.message.contains("Connection refused")
    }

    private func outboundPayload(from plaintext: Data) throws -> Data {
        guard isEncryptedSession else {
            return plaintext
        }
        guard let encryptionKey else {
            throw MoonlightError(.unsupportedOperation, message: "Encrypted RTSP session is missing remote input key material")
        }

        sendSequenceNumber &+= 1
        return try crypto.encrypt(
            plaintext,
            key: encryptionKey,
            sequenceNumber: sendSequenceNumber,
            direction: .clientToHost
        )
    }

    private func inboundMessage(from packet: Data) throws -> Data {
        guard isEncryptedSession else {
            return packet
        }
        guard let encryptionKey else {
            throw MoonlightError(.unsupportedOperation, message: "Encrypted RTSP session is missing remote input key material")
        }
        return try crypto.decrypt(packet, key: encryptionKey, direction: .hostToClient)
    }

    private func send(_ payload: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MoonlightError(.unsupportedOperation, message: "RTSP send failed: \(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveChunk(over connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MoonlightError(.unsupportedOperation, message: "RTSP receive failed: \(error)"))
                    return
                }

                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }

                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: Data())
            }
        }
    }

    private func extractMessageFromBuffer(_ receiveBuffer: inout Data) throws -> Data? {
        if isEncryptedSession {
            guard let packetLength = try encryptedPacketLength(from: receiveBuffer) else {
                return nil
            }
            guard receiveBuffer.count >= packetLength else {
                return nil
            }

            let packet = Data(receiveBuffer.prefix(packetLength))
            receiveBuffer.removeSubrange(..<packetLength)
            return try inboundMessage(from: packet)
        }

        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = receiveBuffer.range(of: separator) else {
            return nil
        }

        let headerData = receiveBuffer[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw MoonlightError(.invalidLaunchResponse, message: "Malformed RTSP response header block")
        }

        let contentLength = parseContentLength(from: headerString) ?? 0
        let totalLength = headerRange.upperBound + contentLength
        guard receiveBuffer.count >= totalLength else {
            return nil
        }

        let message = Data(receiveBuffer[..<totalLength])
        receiveBuffer.removeSubrange(..<totalLength)
        return message
    }

    private func encryptedPacketLength(from buffer: Data) throws -> Int? {
        guard buffer.count >= EncryptedRTSPEnvelope.headerLength else {
            return nil
        }

        let typeAndLength = try UInt32(bigEndianData: buffer.prefix(4))
        guard (typeAndLength & EncryptedRTSPEnvelope.encryptedMessageBit) != 0 else {
            throw MoonlightError(.invalidLaunchResponse, message: "Encrypted RTSP response is missing the encryption flag")
        }

        return EncryptedRTSPEnvelope.headerLength + Int(typeAndLength & ~EncryptedRTSPEnvelope.encryptedMessageBit)
    }

    private func parseContentLength(from headerBlock: String) -> Int? {
        for line in headerBlock.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                continue
            }
            if parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-length") == .orderedSame {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func tryOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOpen else {
            return false
        }
        isOpen = true
        return true
    }
}
#endif
