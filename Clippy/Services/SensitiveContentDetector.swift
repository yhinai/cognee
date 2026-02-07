import Foundation

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
