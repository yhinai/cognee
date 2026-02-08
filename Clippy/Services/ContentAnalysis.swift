import AppKit
import Foundation

enum ClipboardAction: Identifiable, Hashable {
    case openURL(URL)
    case openMaps(String)
    case createEvent(Date)
    case callNumber(String)
    case emailTo(String)
    
    var id: String {
        switch self {
        case .openURL(let url): return "url_\(url.absoluteString)"
        case .openMaps(let address): return "maps_\(address)"
        case .createEvent(let date): return "event_\(date.timeIntervalSinceReferenceDate)"
        case .callNumber(let number): return "call_\(number)"
        case .emailTo(let email): return "email_\(email)"
        }
    }
    
    var iconName: String {
        switch self {
        case .openURL: return "safari"
        case .openMaps: return "map"
        case .createEvent: return "calendar.badge.plus"
        case .callNumber: return "phone.fill"
        case .emailTo: return "envelope.fill"
        }
    }
    
    var label: String {
        switch self {
        case .openURL: return "Open Link"
        case .openMaps: return "Open Maps"
        case .createEvent: return "Add to Calendar"
        case .callNumber: return "Call"
        case .emailTo: return "Email"
        }
    }
    
    @MainActor
    func perform() {
        switch self {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            
        case .openMaps(let address):
            // Apple Maps URL scheme
            if let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
            
        case .createEvent:
            // Opening Calendar app generally
            // Deep linking to create an event is harder without EventKit usage directly,
            // but opening Calendar is a safe "Action".
            // A more advanced version works with EventKit.
            if let appUrl = URL(string: "ical://") {
                NSWorkspace.shared.open(appUrl)
            }
            
        case .callNumber(let number):
            if let url = URL(string: "tel://\(number.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())") {
                NSWorkspace.shared.open(url)
            }
            
        case .emailTo(let email):
            if let url = URL(string: "mailto:\(email)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

class ActionDetector {
    static let shared = ActionDetector()
    private let detector: NSDataDetector?
    
    private init() {
        // We only care about specific types
        let types: NSTextCheckingResult.CheckingType = [.link, .date, .address, .phoneNumber]
        detector = try? NSDataDetector(types: types.rawValue)
    }
    
    func detectActions(in text: String) -> [ClipboardAction] {
        guard let detector = detector, !text.isEmpty else { return [] }
        
        // Limit text length for performance
        let searchRange = NSRange(location: 0, length: min(text.utf16.count, 2000))
        var actions: [ClipboardAction] = []
        
        detector.enumerateMatches(in: text, options: [], range: searchRange) { match, _, stop in
            guard let match = match else { return }
            
            switch match.resultType {
            case .link:
                if let url = match.url {
                    // Valid URL check (sometimes detector finds weird things)
                    if url.scheme?.lowercased().hasPrefix("http") == true {
                        actions.append(.openURL(url))
                    } else if url.scheme?.lowercased() == "mailto" {
                        // handled by link usually but specialized logic below
                        // actions.append(.emailTo(url.absoluteString)) // Simplify
                        actions.append(.openURL(url))
                    }
                }
                
            case .date:
                if let date = match.date {
                    actions.append(.createEvent(date))
                }
                
            case .address:
                if match.components != nil, let range = Range(match.range, in: text) {
                    let addressString = String(text[range])
                    actions.append(.openMaps(addressString))
                }
                
            case .phoneNumber:
                if let number = match.phoneNumber {
                    actions.append(.callNumber(number))
                }
                
            default:
                break
            }
            
            // Limit to first 3 actionable items to avoid clutter
            if actions.count >= 3 {
                stop.pointee = true
            }
        }
        
        // Deduplicate while preserving order
        var seen = Set<ClipboardAction>()
        return actions.filter { seen.insert($0).inserted }
    }
}

struct SensitiveContentDetector {

    /// Check if content contains sensitive information
    static func isSensitive(_ content: String) -> Bool {
        return containsAPIKey(content) ||
               containsCreditCard(content) ||
               containsSSN(content) ||
               containsPrivateKey(content) ||
               containsPassword(content) ||
               containsJWT(content) ||
               containsBearerToken(content) ||
               containsConnectionString(content)
    }

    /// Detect common API key patterns
    static func containsAPIKey(_ content: String) -> Bool {
        let patterns = [
            "sk-[a-zA-Z0-9]{20,}",             // OpenAI
            "AKIA[0-9A-Z]{16}",                 // AWS Access Key
            "ghp_[a-zA-Z0-9]{36}",              // GitHub Personal Access Token
            "gho_[a-zA-Z0-9]{36}",              // GitHub OAuth
            "github_pat_[a-zA-Z0-9_]{22,}",     // GitHub Fine-grained PAT
            "xox[boaprs]-[a-zA-Z0-9-]+",        // Slack tokens
            "AIza[0-9A-Za-z_-]{35}",            // Google API Key
            "sk_live_[a-zA-Z0-9]{24,}",         // Stripe Secret
            "pk_live_[a-zA-Z0-9]{24,}",         // Stripe Publishable
        ]
        return patterns.contains { pattern in
            content.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Detect credit card numbers using Luhn algorithm validation
    static func containsCreditCard(_ content: String) -> Bool {
        let pattern = "\\b(?:4\\d{3}|5[1-5]\\d{2}|3[47]\\d{2}|6(?:011|5\\d{2}))[- ]?(?:\\d{4}[- ]?){2}\\d{1,4}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }

        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        for match in matches {
            if let range = Range(match.range, in: content) {
                let candidate = String(content[range]).filter { $0.isNumber }
                if candidate.count >= 13 && candidate.count <= 19 && luhnCheck(candidate) {
                    return true
                }
            }
        }
        return false
    }

    /// Luhn algorithm check for credit card validation
    private static func luhnCheck(_ number: String) -> Bool {
        let digits = number.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13 else { return false }

        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Detect Social Security Number patterns
    static func containsSSN(_ content: String) -> Bool {
        let pattern = "\\b\\d{3}[- ]\\d{2}[- ]\\d{4}\\b"
        return content.range(of: pattern, options: .regularExpression) != nil
    }

    /// Detect private key blocks (RSA, EC, PGP, etc.)
    static func containsPrivateKey(_ content: String) -> Bool {
        let patterns = [
            "-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
            "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        ]
        return patterns.contains { pattern in
            content.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Detect password manager output and credential patterns
    static func containsPassword(_ content: String) -> Bool {
        let patterns = [
            "(?i)password\\s*[:=]\\s*\\S+",
            "(?i)passwd\\s*[:=]\\s*\\S+",
            "(?i)secret_?key\\s*[:=]\\s*\\S+",
        ]
        return patterns.contains { pattern in
            content.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Detect JSON Web Tokens (JWT)
    static func containsJWT(_ content: String) -> Bool {
        let pattern = "eyJ[A-Za-z0-9\\-_]+\\.eyJ[A-Za-z0-9\\-_]+\\.[A-Za-z0-9\\-_.+/=]+"
        return content.range(of: pattern, options: .regularExpression) != nil
    }

    /// Detect Bearer authentication tokens
    static func containsBearerToken(_ content: String) -> Bool {
        let pattern = "[Bb]earer\\s+[A-Za-z0-9\\-._~+/]+=*"
        return content.range(of: pattern, options: .regularExpression) != nil
    }

    /// Detect database connection strings
    static func containsConnectionString(_ content: String) -> Bool {
        let pattern = "(mongodb|postgres|mysql|redis)://[^\\s]+"
        return content.range(of: pattern, options: .regularExpression) != nil
    }
}
