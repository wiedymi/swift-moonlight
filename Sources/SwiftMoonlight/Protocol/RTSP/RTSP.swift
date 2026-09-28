import Foundation

public enum RTSPMethod: String, Sendable, Equatable {
    case options = "OPTIONS"
    case describe = "DESCRIBE"
    case setup = "SETUP"
    case announce = "ANNOUNCE"
    case play = "PLAY"
}

public struct RTSPHeader: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum RTSPMessage: Sendable, Equatable {
    case request(RTSPRequest)
    case response(RTSPResponse)

    public var headers: [RTSPHeader] {
        switch self {
        case let .request(request):
            return request.headers
        case let .response(response):
            return response.headers
        }
    }

    public func headerValue(named name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct RTSPRequest: Sendable, Equatable {
    public var method: RTSPMethod
    public var target: String
    public var protocolVersion: String
    public var headers: [RTSPHeader]
    public var body: Data?

    public init(
        method: RTSPMethod,
        target: String,
        protocolVersion: String = "RTSP/1.0",
        headers: [RTSPHeader] = [],
        body: Data? = nil
    ) {
        self.method = method
        self.target = target
        self.protocolVersion = protocolVersion
        self.headers = headers
        self.body = body
    }

    public func serialized() -> Data {
        var lines = ["\(method.rawValue) \(target) \(protocolVersion)"]
        lines.append(contentsOf: headers.map { "\($0.name): \($0.value)" })
        let headerBlock = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(headerBlock.utf8)
        if let body {
            data.append(body)
        }
        return data
    }
}

public struct RTSPResponse: Sendable, Equatable {
    public var protocolVersion: String
    public var statusCode: Int
    public var statusText: String
    public var headers: [RTSPHeader]
    public var body: Data?

    public init(
        protocolVersion: String = "RTSP/1.0",
        statusCode: Int,
        statusText: String,
        headers: [RTSPHeader] = [],
        body: Data? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.statusCode = statusCode
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    public func serialized() -> Data {
        var lines = ["\(protocolVersion) \(statusCode) \(statusText)"]
        lines.append(contentsOf: headers.map { "\($0.name): \($0.value)" })
        let headerBlock = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(headerBlock.utf8)
        if let body {
            data.append(body)
        }
        return data
    }
}

public struct RTSPMessageParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> RTSPMessage {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw MoonlightError(.invalidLaunchResponse, message: "Malformed RTSP message: missing header terminator")
        }

        let headerData = data[..<separatorRange.lowerBound]
        let bodyStart = separatorRange.upperBound
        let body = bodyStart < data.endIndex ? Data(data[bodyStart...]) : nil

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw MoonlightError(.invalidLaunchResponse, message: "Malformed RTSP message: non-UTF8 header block")
        }

        var lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            throw MoonlightError(.invalidLaunchResponse, message: "Malformed RTSP message: missing start line")
        }
        lines.removeFirst()

        let headers = try parseHeaders(lines)

        if firstLine.hasPrefix("RTSP/") {
            let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let statusCode = Int(parts[1]) else {
                throw MoonlightError(.invalidLaunchResponse, message: "Malformed RTSP response start line")
            }
            return .response(
                RTSPResponse(
                    protocolVersion: String(parts[0]),
                    statusCode: statusCode,
                    statusText: String(parts[2]),
                    headers: headers,
                    body: body
                )
            )
        } else {
            let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let method = RTSPMethod(rawValue: String(parts[0])) else {
                throw MoonlightError(.invalidLaunchResponse, message: "Malformed RTSP request start line")
            }
            return .request(
                RTSPRequest(
                    method: method,
                    target: String(parts[1]),
                    protocolVersion: String(parts[2]),
                    headers: headers,
                    body: body
                )
            )
        }
    }

    private func parseHeaders(_ lines: [String]) throws -> [RTSPHeader] {
        try lines.filter { !$0.isEmpty }.map { line in
            guard let separator = line.firstIndex(of: ":") else {
                throw MoonlightError(.invalidLaunchResponse, message: "Malformed RTSP header: \(line)")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            return RTSPHeader(name: name, value: value)
        }
    }
}

public struct RTSPSessionInfo: Sendable, Equatable {
    public var sessionID: String?
    public var serverPort: UInt16?
    public var pingPayload: String?
    public var controlConnectData: UInt32?

    public init(
        sessionID: String? = nil,
        serverPort: UInt16? = nil,
        pingPayload: String? = nil,
        controlConnectData: UInt32? = nil
    ) {
        self.sessionID = sessionID
        self.serverPort = serverPort
        self.pingPayload = pingPayload
        self.controlConnectData = controlConnectData
    }
}

public struct RTSPSessionInfoParser: Sendable {
    public init() {}

    public func parseSetupResponse(_ response: RTSPResponse) -> RTSPSessionInfo {
        RTSPSessionInfo(
            sessionID: parseSessionID(response.headers),
            serverPort: parseServerPort(response.headers),
            pingPayload: response.headers.first { $0.name.caseInsensitiveCompare("X-SS-Ping-Payload") == .orderedSame }?.value,
            controlConnectData: parseControlConnectData(response.headers)
        )
    }

    private func parseSessionID(_ headers: [RTSPHeader]) -> String? {
        guard let raw = headers.first(where: { $0.name.caseInsensitiveCompare("Session") == .orderedSame })?.value else {
            return nil
        }
        return raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
    }

    private func parseServerPort(_ headers: [RTSPHeader]) -> UInt16? {
        guard let transport = headers.first(where: { $0.name.caseInsensitiveCompare("Transport") == .orderedSame })?.value else {
            return nil
        }
        let parts = transport.split(separator: ";").map(String.init)
        guard let portPart = parts.first(where: { $0.hasPrefix("server_port=") }) else {
            return nil
        }
        let value = portPart.dropFirst("server_port=".count)
        let firstPort = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first
        return firstPort.flatMap { UInt16($0) }
    }

    private func parseControlConnectData(_ headers: [RTSPHeader]) -> UInt32? {
        guard let raw = headers.first(where: { $0.name.caseInsensitiveCompare("X-SS-Connect-Data") == .orderedSame })?.value else {
            return nil
        }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return UInt32(raw.dropFirst(2), radix: 16)
        }
        return UInt32(raw)
    }
}

public struct RTSPDescribeInfo: Sendable, Equatable {
    public var encryptionSupported: SessionEncryptionFeatures
    public var encryptionRequested: SessionEncryptionFeatures
    public var sdp: String?

    public init(
        encryptionSupported: SessionEncryptionFeatures = [],
        encryptionRequested: SessionEncryptionFeatures = [],
        sdp: String? = nil
    ) {
        self.encryptionSupported = encryptionSupported
        self.encryptionRequested = encryptionRequested
        self.sdp = sdp
    }
}

public struct RTSPDescribeInfoParser: Sendable {
    public init() {}

    public func parseDescribeResponse(_ response: RTSPResponse) -> RTSPDescribeInfo {
        guard let body = response.body,
              let sdp = String(data: body, encoding: .utf8)
        else {
            return RTSPDescribeInfo()
        }

        return RTSPDescribeInfo(
            encryptionSupported: parseEncryptionFeatures(named: "x-ss-general.encryptionSupported", in: sdp),
            encryptionRequested: parseEncryptionFeatures(named: "x-ss-general.encryptionRequested", in: sdp),
            sdp: sdp
        )
    }

    private func parseEncryptionFeatures(named attribute: String, in sdp: String) -> SessionEncryptionFeatures {
        let needle = "\(attribute):"
        guard let line = sdp
            .components(separatedBy: .newlines)
            .first(where: { $0.contains(needle) }),
              let value = line.split(separator: ":", maxSplits: 1).last,
              let rawValue = UInt32(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return []
        }

        return SessionEncryptionFeatures(rawValue: rawValue)
    }
}

public struct OpusConfigurationParser: Sendable {
    public init() {}

    public func parse(sdp: String, audioMode: AudioMode) throws -> OpusStreamConfiguration {
        let channelCount = audioMode.channelCount
        if channelCount == 2 {
            return .stereo()
        }

        let prefix = "a=fmtp:97 surround-params=\(channelCount)"
        let matches = sdp.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix(prefix) }

        if let first = matches.first {
            let suffix = String(first.dropFirst(prefix.count))
            var parsed = try parseParamSuffix(suffix, channelCount: channelCount)

            if channelCount == 6 || channelCount == 8 {
                let original = parsed.mapping
                parsed.mapping[3] = original[channelCount - 1]
                if channelCount > 4 {
                    for index in 4..<channelCount {
                        parsed.mapping[index] = original[index - 1]
                    }
                }
            }

            return parsed
        }

        if channelCount == 6 {
            return OpusStreamConfiguration(
                sampleRate: 48_000,
                channelCount: 6,
                streams: 4,
                coupledStreams: 2,
                samplesPerFrame: 960,
                mapping: [0, 4, 1, 5, 2, 3]
            )
        }

        throw MoonlightError(.unsupportedOperation, message: "No Opus surround parameters found for channel count \(channelCount)")
    }

    private func parseParamSuffix(_ suffix: String, channelCount: Int) throws -> OpusStreamConfiguration {
        let digits = Array(suffix)
        guard digits.count >= 2 + channelCount else {
            throw MoonlightError(.unsupportedOperation, message: "Opus surround parameter string is too short")
        }

        guard let streams = Int(String(digits[0])),
              let coupledStreams = Int(String(digits[1]))
        else {
            throw MoonlightError(.unsupportedOperation, message: "Opus surround parameter header is invalid")
        }

        var mapping: [UInt8] = []
        mapping.reserveCapacity(channelCount)
        for index in 0..<channelCount {
            guard let value = UInt8(String(digits[index + 2])) else {
                throw MoonlightError(.unsupportedOperation, message: "Opus mapping contains invalid digit at index \(index)")
            }
            mapping.append(value)
        }

        return OpusStreamConfiguration(
            sampleRate: 48_000,
            channelCount: channelCount,
            streams: streams,
            coupledStreams: coupledStreams,
            samplesPerFrame: 960,
            mapping: mapping
        )
    }
}

public struct RTSPRequestFactory: Sendable {
    public var clientVersion: Int

    public init(clientVersion: Int = 14) {
        self.clientVersion = clientVersion
    }

    public func describe(url: String, cSeq: Int) -> RTSPRequest {
        RTSPRequest(
            method: .describe,
            target: url,
            headers: commonHeaders(for: url, cSeq: cSeq) + [
                .init(name: "Accept", value: "application/sdp"),
                .init(name: "If-Modified-Since", value: "Thu, 01 Jan 1970 00:00:00 GMT"),
            ]
        )
    }

    public func options(url: String, cSeq: Int) -> RTSPRequest {
        RTSPRequest(
            method: .options,
            target: url,
            headers: commonHeaders(for: url, cSeq: cSeq)
        )
    }

    public func setup(target: String, sessionURL: String, cSeq: Int, sessionID: String?) -> RTSPRequest {
        var headers: [RTSPHeader] = commonHeaders(for: sessionURL, cSeq: cSeq) + [
            .init(name: "Transport", value: "unicast;X-GS-ClientPort=50000-50001"),
            .init(name: "If-Modified-Since", value: "Thu, 01 Jan 1970 00:00:00 GMT"),
        ]
        if let sessionID {
            headers.append(.init(name: "Session", value: sessionID))
        }
        return RTSPRequest(method: .setup, target: target, headers: headers)
    }

    public func announce(target: String, sessionURL: String, cSeq: Int, sessionID: String, sdp: Data) -> RTSPRequest {
        RTSPRequest(
            method: .announce,
            target: target,
            headers: commonHeaders(for: sessionURL, cSeq: cSeq) + [
                .init(name: "Session", value: sessionID),
                .init(name: "Content-type", value: "application/sdp"),
                .init(name: "Content-length", value: "\(sdp.count)"),
            ],
            body: sdp
        )
    }

    public func play(target: String, sessionURL: String, cSeq: Int, sessionID: String) -> RTSPRequest {
        RTSPRequest(
            method: .play,
            target: target,
            headers: commonHeaders(for: sessionURL, cSeq: cSeq) + [
                .init(name: "Session", value: sessionID),
            ]
        )
    }

    private func commonHeaders(for sessionURL: String, cSeq: Int) -> [RTSPHeader] {
        var headers: [RTSPHeader] = [
            .init(name: "CSeq", value: "\(cSeq)"),
            .init(name: "X-GS-ClientVersion", value: "\(clientVersion)"),
        ]

        if let url = URL(string: sessionURL),
           let host = url.host(percentEncoded: false) ?? url.host,
           let port = url.port {
            headers.append(.init(name: "Host", value: "\(host):\(port)"))
        }

        return headers
    }
}
