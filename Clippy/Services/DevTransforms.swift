import CryptoKit
import Foundation

// MARK: - Transform Category

enum TransformCategory: String, CaseIterable {
    case encoding = "Encoding"
    case format = "Format"
    case crypto = "Crypto"
    case text = "Text"
    case extract = "Extract"
}

// MARK: - Text Transform

struct TextTransform: Identifiable {
    let id: String
    let name: String
    let icon: String
    let category: TransformCategory
    let transform: (String) -> String
}

// MARK: - Transform Registry

class TransformRegistry {
    static let shared = TransformRegistry()

    let transforms: [TextTransform]

    private init() {
        transforms = [
            // Encoding
            TextTransform(id: "base64_encode", name: "Base64 Encode", icon: "arrow.right.circle", category: .encoding) { input in
                Data(input.utf8).base64EncodedString()
            },
            TextTransform(id: "base64_decode", name: "Base64 Decode", icon: "arrow.left.circle", category: .encoding) { input in
                guard let data = Data(base64Encoded: input),
                      let decoded = String(data: data, encoding: .utf8) else {
                    return "[Invalid Base64]"
                }
                return decoded
            },
            TextTransform(id: "url_encode", name: "URL Encode", icon: "link", category: .encoding) { input in
                input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
            },
            TextTransform(id: "url_decode", name: "URL Decode", icon: "link.badge.plus", category: .encoding) { input in
                input.removingPercentEncoding ?? input
            },

            // Format
            TextTransform(id: "json_pretty", name: "JSON Pretty Print", icon: "doc.text", category: .format) { input in
                guard let data = input.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                      let result = String(data: pretty, encoding: .utf8) else {
                    return "[Invalid JSON]"
                }
                return result
            },
            TextTransform(id: "json_minify", name: "JSON Minify", icon: "doc.text.fill", category: .format) { input in
                guard let data = input.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let compact = try? JSONSerialization.data(withJSONObject: json, options: []),
                      let result = String(data: compact, encoding: .utf8) else {
                    return "[Invalid JSON]"
                }
                return result
            },
            TextTransform(id: "camel_to_snake", name: "camelCase to snake_case", icon: "textformat.abc", category: .format) { input in
                var result = ""
                for (i, char) in input.enumerated() {
                    if char.isUppercase && i > 0 {
                        result += "_"
                    }
                    result += char.lowercased()
                }
                return result
            },
            TextTransform(id: "snake_to_camel", name: "snake_case to camelCase", icon: "textformat.abc.dottedunderline", category: .format) { input in
                let parts = input.split(separator: "_")
                guard let first = parts.first else { return input }
                let rest = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                return first.lowercased() + rest.joined()
            },

            // Crypto
            TextTransform(id: "sha256", name: "SHA-256 Hash", icon: "lock.shield", category: .crypto) { input in
                let digest = SHA256.hash(data: Data(input.utf8))
                return digest.map { String(format: "%02x", $0) }.joined()
            },

            // Text
            TextTransform(id: "sort_lines", name: "Sort Lines", icon: "arrow.up.arrow.down", category: .text) { input in
                input.components(separatedBy: "\n").sorted().joined(separator: "\n")
            },
            TextTransform(id: "dedup_lines", name: "Deduplicate Lines", icon: "minus.circle", category: .text) { input in
                var seen = Set<String>()
                return input.components(separatedBy: "\n").filter { seen.insert($0).inserted }.joined(separator: "\n")
            },
            TextTransform(id: "trim", name: "Trim Whitespace", icon: "scissors", category: .text) { input in
                input.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            TextTransform(id: "count_stats", name: "Count Stats", icon: "number", category: .text) { input in
                let lines = input.components(separatedBy: "\n").count
                let words = input.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                let chars = input.count
                return "Lines: \(lines) | Words: \(words) | Characters: \(chars)"
            },

            // Extract
            TextTransform(id: "extract_urls", name: "Extract URLs", icon: "globe", category: .extract) { input in
                let pattern = "https?://[^\\s<>\"']+"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
                let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
                let urls = matches.compactMap { Range($0.range, in: input).map { String(input[$0]) } }
                return urls.isEmpty ? "[No URLs found]" : urls.joined(separator: "\n")
            },
            TextTransform(id: "extract_emails", name: "Extract Emails", icon: "envelope", category: .extract) { input in
                let pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
                let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
                let emails = matches.compactMap { Range($0.range, in: input).map { String(input[$0]) } }
                return emails.isEmpty ? "[No emails found]" : emails.joined(separator: "\n")
            },
        ]
    }

    func transforms(for category: TransformCategory) -> [TextTransform] {
        transforms.filter { $0.category == category }
    }
}
