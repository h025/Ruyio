import Foundation
import RuyioCore

/// One release in a Sparkle-format appcast (A41). Ruyio reads only what it needs; the feed and its EdDSA
/// signatures are made with Sparkle's own tools, so switching to Sparkle later needs no new feed.
public struct AppcastItem: Sendable, Hashable {
    /// `sparkle:shortVersionString`, compared with the running app's CFBundleShortVersionString.
    public var version: SemanticVersion
    public var minimumSystemVersion: OSVersion?
    public var url: URL
    public var length: Int64
    /// Base64 Ed25519 signature of the archive (`sparkle:edSignature`).
    public var edSignature: String
    public var releaseNotesURL: URL?

    public init(version: SemanticVersion, minimumSystemVersion: OSVersion?, url: URL, length: Int64, edSignature: String, releaseNotesURL: URL?) {
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
        self.url = url
        self.length = length
        self.edSignature = edSignature
        self.releaseNotesURL = releaseNotesURL
    }
}

public enum Appcast {
    /// Items that carry everything an update needs; incomplete or non-https items are skipped, not fatal.
    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw RuyioError(.sourceInvalid, diagnostic: "appcast is not valid XML") }
        return reader.items
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var fields: [String: String]?
        private var enclosure: [String: String] = [:]
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "item": fields = [:]; enclosure = [:]
            // Only the item's own enclosure: the ones inside <sparkle:deltas> are patches, not the archive.
            case "enclosure" where fields != nil && path.last == "item": enclosure = attributes
            default: break
            }
            path.append(name)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            path.removeLast()
            guard fields != nil else { return }
            if name == "item" {
                if let item = makeItem() { items.append(item) }
                fields = nil
            } else if path.last == "item" {
                fields?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        private func makeItem() -> AppcastItem? {
            // Items on a named channel (beta and the like) are for clients that opted in; Ruyio has none.
            guard let fields, fields["sparkle:channel"] == nil else { return nil }
            // Sparkle accepts the versions as elements or, in older feeds, as enclosure attributes.
            let short = fields["sparkle:shortVersionString"] ?? enclosure["sparkle:shortVersionString"]
            guard let short, let version = SemanticVersion(short),
                  let urlString = enclosure["url"], let url = URL(string: urlString), url.scheme == "https",
                  let signature = enclosure["sparkle:edSignature"], !signature.isEmpty else { return nil }
            let notes = fields["sparkle:releaseNotesLink"].flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            return AppcastItem(version: version, minimumSystemVersion: fields["sparkle:minimumSystemVersion"].flatMap(OSVersion.init),
                               url: url, length: enclosure["length"].flatMap { Int64($0) } ?? 0, edSignature: signature,
                               releaseNotesURL: notes)
        }
    }
}
