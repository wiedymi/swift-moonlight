import Foundation

public struct ServerInfo: Sendable, Equatable {
    public var appVersion: String?
    public var gfeVersion: String?
    public var rtspSessionURL: String?
    public var httpsPort: Int?
    public var codecSupportFlags: UInt32
    public var pairingState: PairingState
    public var permissionMask: UInt32?

    public init(
        appVersion: String?,
        gfeVersion: String?,
        rtspSessionURL: String?,
        httpsPort: Int?,
        codecSupportFlags: UInt32,
        pairingState: PairingState,
        permissionMask: UInt32? = nil
    ) {
        self.appVersion = appVersion
        self.gfeVersion = gfeVersion
        self.rtspSessionURL = rtspSessionURL
        self.httpsPort = httpsPort
        self.codecSupportFlags = codecSupportFlags
        self.pairingState = pairingState
        self.permissionMask = permissionMask
    }
}

public struct HostSnapshot: Sendable, Equatable {
    public var host: MoonlightHost
    public var serverInfo: ServerInfo

    public init(host: MoonlightHost, serverInfo: ServerInfo) {
        self.host = host
        self.serverInfo = serverInfo
    }
}

public struct HostInfoParser {
    public init() {}

    public func parseServerInfo(_ data: Data) throws -> ServerInfo {
        let document = try XMLScalarDocument(data: data)

        let pairedValue = document.firstValue(forElementNamed: "paired")
            ?? document.firstValue(forElementNamed: "PairStatus")
        let pairingState: PairingState
        switch pairedValue {
        case "1":
            pairingState = .paired
        case "0":
            pairingState = .unpaired
        default:
            pairingState = .unknown
        }

        return ServerInfo(
            appVersion: document.firstValue(forElementNamed: "appversion"),
            gfeVersion: document.firstValue(forElementNamed: "GfeVersion"),
            rtspSessionURL: document.firstValue(forElementNamed: "sessionUrl0"),
            httpsPort: Int(document.firstValue(forElementNamed: "HttpsPort") ?? ""),
            codecSupportFlags: UInt32(document.firstValue(forElementNamed: "ServerCodecModeSupport") ?? "0") ?? 0,
            pairingState: pairingState,
            permissionMask: document.firstValue(forElementNamed: "Permission").flatMap(UInt32.init)
        )
    }
}

public struct AppListParser {
    public init() {}

    public func parseAppList(_ data: Data) throws -> [RemoteApp] {
        let document = try XMLDocument(data: data)
        let apps = document.elements(named: "App")

        return apps.compactMap { app in
            guard
                let id = app.firstChildValue(named: "ID"),
                let title = app.firstChildValue(named: "AppTitle")
            else {
                return nil
            }

            return RemoteApp(
                id: id,
                name: title,
                supportsHDR: Self.boolValue(app.firstChildValue(named: "IsHdrSupported"))
            )
        }
    }

    private static func boolValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return value == "1" || value.lowercased() == "true"
    }
}

private final class XMLDocument: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var currentElementName: String?
    private var currentText = ""
    private var valueMap: [String: [String]] = [:]
    private var elementStack: [String] = []
    private var appNodes: [[String: String]] = []
    private var currentAppNode: [String: String]?

    init(data: Data) throws {
        guard let parser = XMLParser(data: data) as XMLParser? else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to initialize XML parser")
        }
        self.parser = parser
        super.init()
        self.parser.delegate = self
        guard self.parser.parse() else {
            let message = self.parser.parserError?.localizedDescription ?? "XML parse failed"
            throw MoonlightError(.unsupportedOperation, message: message)
        }
    }

    func firstValue(forElementNamed name: String) -> String? {
        valueMap[name]?.first
    }

    func elements(named name: String) -> [XMLNode] {
        guard name == "App" else { return [] }
        return appNodes.map(XMLNode.init(values:))
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        _ = namespaceURI
        _ = qName
        _ = attributeDict
        elementStack.append(elementName)
        currentElementName = elementName
        currentText = ""

        if elementName == "App" {
            currentAppNode = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        _ = parser
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = parser
        _ = namespaceURI
        _ = qName
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            valueMap[elementName, default: []].append(trimmed)
            currentAppNode?[elementName] = trimmed
        }

        if elementName == "App", let currentAppNode {
            appNodes.append(currentAppNode)
            self.currentAppNode = nil
        }

        _ = elementStack.popLast()
        currentElementName = elementStack.last
        currentText = ""
    }
}

private struct XMLNode {
    let values: [String: String]

    func firstChildValue(named name: String) -> String? {
        values[name]
    }
}
