import Foundation
import RuyioCore

public enum ClipboardWriteValidator {
    /// A file history entry stores references, not file contents. Validate the complete batch before
    /// any pasteboard mutation so one stale path cannot clear the user's current clipboard.
    public static func validateFileReferences(_ items: [[String: Data]]) throws {
        for item in items {
            guard let data = item["public.file-url"] else { continue }
            guard let text = String(data: data, encoding: .utf8),
                  let url = URL(string: text), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  (try? url.checkResourceIsReachable()) == true,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw RuyioError(.fileAccessDenied, recovery: .retry, diagnostic: "clipboard file reference is unavailable")
            }
        }
    }
}
