import Foundation

final class XMLScalarDocument: NSObject, XMLParserDelegate {
    private var elementStack: [String] = []
    private var currentText = ""
    private var valueMap: [String: [String]] = [:]
    private var attributeMap: [String: [String: String]] = [:]

    init(data: Data) throws {
        super.init()

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse() else {
            let preview = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            let snippet = preview.isEmpty ? "<empty>" : String(preview.prefix(240))
            throw MoonlightError(
                .unsupportedOperation,
                message: "Malformed XML document: \(snippet)"
            )
        }
    }

    func firstValue(forElementNamed name: String) -> String? {
        valueMap[name]?.first
    }

    func attribute(named name: String, onElementNamed elementName: String) -> String? {
        attributeMap[elementName]?[name]
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        _ = parser
        _ = namespaceURI
        _ = qName
        elementStack.append(elementName)
        currentText = ""
        if !attributeDict.isEmpty {
            attributeMap[elementName] = attributeDict
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        _ = parser
        currentText.append(string)
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
        }

        if elementStack.last == elementName {
            elementStack.removeLast()
        }

        currentText = ""
    }
}
