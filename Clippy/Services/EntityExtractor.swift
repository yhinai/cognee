import Foundation

/// Swift port of the Python backend's entity extraction (regex-based).
/// Detects URLs, emails, phone numbers, dates, money, and file paths.
struct EntityExtractor {
    
    struct Entity: Codable, Hashable {
        let type: String
        let value: String
    }

    // MARK: - Patterns

    private static let patterns: [(String, NSRegularExpression)] = {
        let defs: [(String, String)] = [
            ("url", #"https?://[^\s<>"{}|\\^`\[\]]+"#),
            ("email", #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#),
            ("phone", #"(?:\+\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#),
            ("date", #"\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b|\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b"#),
            ("money", #"\$[\d,]+(?:\.\d{2})?"#),
            ("file_path", #"(?:/[\w.-]+){2,}|[A-Z]:\\(?:[\w.-]+\\?)+"#),
        ]
        return defs.compactMap { (type, pattern) in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (type, regex)
        }
    }()

    // MARK: - Extraction

    /// Extract all entities from the given text.
    static func extract(from text: String) -> [Entity] {
        var seen = Set<Entity>()
        var results: [Entity] = []

        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        for (type, regex) in patterns {
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let value = String(text[matchRange]).trimmingCharacters(in: .whitespaces)
                let entity = Entity(type: type, value: value)
                if !seen.contains(entity) {
                    seen.insert(entity)
                    results.append(entity)
                }
            }
        }

        return results
    }

    /// Extract entities and return as a dictionary grouped by type.
    static func extractGrouped(from text: String) -> [String: [String]] {
        let entities = extract(from: text)
        var grouped: [String: [String]] = [:]
        for entity in entities {
            grouped[entity.type, default: []].append(entity.value)
        }
        return grouped
    }
}
