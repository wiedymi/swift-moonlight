import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct HTTPSClientIdentityMaterial: Sendable {
    public var certificatePEM: String
    public var privateKeyPEM: String

    public init(certificatePEM: String, privateKeyPEM: String) {
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private final class TrustDelegate: NSObject, URLSessionDelegate {
        let allowSelfSignedCertificates: Bool

        init(allowSelfSignedCertificates: Bool) {
            self.allowSelfSignedCertificates = allowSelfSignedCertificates
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            _ = session
            #if canImport(Security)
            guard allowSelfSignedCertificates,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            #else
            completionHandler(.performDefaultHandling, nil)
            #endif
        }
    }

    private let session: URLSession
    private let httpsClientIdentityProvider: (@Sendable () async throws -> HTTPSClientIdentityMaterial?)?

    public init(
        session: URLSession? = nil,
        allowSelfSignedCertificates: Bool = true,
        httpsClientIdentityProvider: (@Sendable () async throws -> HTTPSClientIdentityMaterial?)? = nil
    ) {
        self.httpsClientIdentityProvider = httpsClientIdentityProvider
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            let delegate = TrustDelegate(allowSelfSignedCertificates: allowSelfSignedCertificates)
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    public func get(url: URL, headers: [String : String] = [:]) async throws -> (Data, HTTPURLResponse) {
        #if os(macOS)
        if url.scheme?.lowercased() == "https", let httpsClientIdentityProvider {
            if let identity = try await httpsClientIdentityProvider() {
                return try await runCurlAuthenticatedRequest(url: url, headers: headers, identity: identity)
            }
        }
        #endif

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoonlightError(.unsupportedOperation, message: "Expected HTTP response from \(url.absoluteString)")
        }

        return (data, httpResponse)
    }

    #if os(macOS)
    private func runCurlAuthenticatedRequest(
        url: URL,
        headers: [String: String],
        identity: HTTPSClientIdentityMaterial
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let certificateURL = tempDirectory.appending(path: "client-cert.pem")
        let privateKeyURL = tempDirectory.appending(path: "client-key.pem")
        let headerURL = tempDirectory.appending(path: "headers.txt")
        let bodyURL = tempDirectory.appending(path: "body.bin")

        try identity.certificatePEM.write(to: certificateURL, atomically: true, encoding: .utf8)
        try identity.privateKeyPEM.write(to: privateKeyURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

        var arguments = [
            "--silent",
            "--show-error",
            "--connect-timeout", "5",
            "--max-time", "15",
            "--insecure",
            "--cert", certificateURL.path(percentEncoded: false),
            "--key", privateKeyURL.path(percentEncoded: false),
            "--dump-header", headerURL.path(percentEncoded: false),
            "--output", bodyURL.path(percentEncoded: false),
            "--write-out", "%{http_code}",
            url.absoluteString,
        ]
        for (field, value) in headers.sorted(by: { $0.key < $1.key }) {
            arguments.insert(contentsOf: ["--header", "\(field): \(value)"], at: arguments.count - 1)
        }
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try await process.runUntilExit()

        let statusData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MoonlightError(.unsupportedOperation, message: errorText.isEmpty ? "curl failed with status \(process.terminationStatus)" : errorText)
        }

        let bodyData = try Data(contentsOf: bodyURL)
        let statusCode = Int(String(decoding: statusData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let headerFields = try parseCurlHeaders(at: headerURL)
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headerFields) else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to build HTTP response for \(url.absoluteString)")
        }
        return (bodyData, response)
    }

    private func parseCurlHeaders(at url: URL) throws -> [String: String] {
        let headerText = try String(contentsOf: url, encoding: .utf8)
        let blocks = headerText
            .components(separatedBy: "\r\n\r\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let lastBlock = blocks.last else {
            return [:]
        }

        var fields: [String: String] = [:]
        for line in lastBlock.split(whereSeparator: \.isNewline).dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            fields[name] = value
        }
        return fields
    }
    #endif
}
