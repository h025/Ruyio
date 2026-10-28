import AppKit
import SwiftUI

/// Indents and colours JSON for the `json` schema node. Works on the text itself rather than on a parsed
/// value, so key order and number spelling stay exactly as copied, and text that was cut short or is not
/// quite valid still comes out readable.
public enum JSONFormatting {
    /// Longest formatted text shown; beyond it the view stops with an ellipsis line.
    public static let displayLimit = 80_000

    public static func indented(_ text: String, indent: Int = 2) -> String {
        var out = ""
        var written = 0
        var level = 0
        var inString = false
        var escaped = false
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        func append(_ piece: String) {
            out.append(piece)
            written += piece.count
        }
        func newline() { append("\n" + String(repeating: " ", count: max(0, level) * indent)) }
        var index = 0
        while index < chars.count, written < displayLimit {
            let c = chars[index]
            index += 1
            if inString {
                append(String(c))
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
                append(String(c))
            case "{", "[":
                // Empty containers stay on one line.
                var next = index
                while next < chars.count, chars[next] == " " || chars[next] == "\n" || chars[next] == "\r" || chars[next] == "\t" { next += 1 }
                if next < chars.count, chars[next] == (c == "{" ? "}" : "]") {
                    append(String(c) + String(chars[next]))
                    index = next + 1
                } else {
                    append(String(c))
                    level += 1
                    newline()
                }
            case "}", "]":
                level -= 1
                newline()
                append(String(c))
            case ",":
                append(",")
                newline()
            case ":":
                append(": ")
            case " ", "\n", "\r", "\t":
                break
            default:
                append(String(c))
            }
        }
        if index < chars.count { out.append("\n…") }
        return out
    }

    enum Token: Equatable { case key, string, number, literal, punctuation, plain }

    /// Token runs of already indented JSON; a string followed by a colon is a key.
    static func tokens(_ text: String) -> [(String, Token)] {
        let chars = Array(text)
        var runs: [(String, Token)] = []
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\"" {
                var end = index + 1
                var escaped = false
                while end < chars.count {
                    if escaped { escaped = false } else if chars[end] == "\\" { escaped = true } else if chars[end] == "\"" { break }
                    end += 1
                }
                end = min(end + 1, chars.count)
                var after = end
                while after < chars.count, chars[after] == " " { after += 1 }
                let isKey = after < chars.count && chars[after] == ":"
                runs.append((String(chars[index..<end]), isKey ? .key : .string))
                index = end
            } else if c == "-" || c.isNumber {
                var end = index + 1
                while end < chars.count, chars[end].isNumber || ".eE+-".contains(chars[end]) { end += 1 }
                runs.append((String(chars[index..<end]), .number))
                index = end
            } else if c.isLetter {
                var end = index + 1
                while end < chars.count, chars[end].isLetter { end += 1 }
                let word = String(chars[index..<end])
                runs.append((word, ["true", "false", "null"].contains(word) ? .literal : .plain))
                index = end
            } else if "{}[]:,".contains(c) {
                runs.append((String(c), .punctuation))
                index += 1
            } else {
                var end = index + 1
                while end < chars.count, !"\"-{}[]:,".contains(chars[end]), !chars[end].isNumber, !chars[end].isLetter { end += 1 }
                runs.append((String(chars[index..<end]), .plain))
                index = end
            }
        }
        return runs
    }

    /// System colours, so both appearances and increased contrast are handled by AppKit.
    public static func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (run, token) in tokens(text) {
            var piece = AttributedString(run)
            switch token {
            case .key: piece.foregroundColor = Color(nsColor: .systemBlue)
            case .string: piece.foregroundColor = Color(nsColor: .systemRed)
            case .number: piece.foregroundColor = Color(nsColor: .systemOrange)
            case .literal: piece.foregroundColor = Color(nsColor: .systemPink)
            case .punctuation: piece.foregroundColor = Color(nsColor: .secondaryLabelColor)
            case .plain: break
            }
            result.append(piece)
        }
        return result
    }
}
