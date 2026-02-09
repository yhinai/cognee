import Foundation
import os
import Security

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.clippy.app"

    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let vector = Logger(subsystem: subsystem, category: "vector")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let services = Logger(subsystem: subsystem, category: "services")
    static let network = Logger(subsystem: subsystem, category: "network")
}


actor TokenBucketRateLimiter {
    private var tokens: Double
    private let maxTokens: Double
    private let refillRate: Double
    private var lastRefill: Date

    init(maxTokens: Double = 10, refillRate: Double = 2) {
        self.tokens = maxTokens
        self.maxTokens = maxTokens
        self.refillRate = refillRate
        self.lastRefill = Date()
    }

    func acquire() async {
        refill()
        if tokens >= 1 {
            tokens -= 1
            return
        }
        let waitTime = (1 - tokens) / refillRate
        try? await Task.sleep(for: .seconds(waitTime))
        refill()
        tokens = max(0, tokens - 1)
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        tokens = min(maxTokens, tokens + elapsed * refillRate)
        lastRefill = now
    }
}


/// Circuit breaker for cloud API calls.
/// States: closed (normal) -> open (failing, reject calls) -> halfOpen (test one call).
actor CircuitBreaker {
    enum State {
        case closed
        case open
        case halfOpen
    }

    private(set) var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailureTime: Date?

    private let failureThreshold: Int
    private let resetTimeout: TimeInterval
    private let name: String

    init(name: String, failureThreshold: Int = 5, resetTimeout: TimeInterval = 60) {
        self.name = name
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
    }

    /// Check if the circuit allows a call through.
    var canExecute: Bool {
        switch state {
        case .closed:
            return true
        case .open:
            // Check if reset timeout has elapsed
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) > resetTimeout {
                state = .halfOpen
                Logger.network.info("Circuit breaker [\(self.name, privacy: .public)]: open -> halfOpen")
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }

    /// Record a successful call.
    func recordSuccess() {
        failureCount = 0
        if state != .closed {
            Logger.network.info("Circuit breaker [\(self.name, privacy: .public)]: \(String(describing: self.state), privacy: .public) -> closed")
        }
        state = .closed
    }

    /// Record a failed call.
    func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()

        if failureCount >= failureThreshold {
            state = .open
            Logger.network.warning("Circuit breaker [\(self.name, privacy: .public)]: opened after \(self.failureCount, privacy: .public) failures")
        }
    }

}

enum CircuitBreakerError: Error, LocalizedError {
    case circuitOpen

    var errorDescription: String? {
        switch self {
        case .circuitOpen:
            return "Service temporarily unavailable. Retrying soon."
        }
    }
}


/// Tracks AI API usage per provider with estimated costs.
@MainActor
class UsageTracker: ObservableObject {

    struct UsageRecord: Codable {
        let providerId: String
        let timestamp: Date
        let estimatedTokens: Int
        let estimatedCost: Double
    }

    @Published var todayCalls: Int = 0
    @Published var todayCost: Double = 0.0
    @Published var perProviderToday: [String: (calls: Int, cost: Double)] = [:]

    private var records: [UsageRecord] = []
    private let storageKey = "ClippyUsageRecords"

    // Estimated cost per 1K tokens (input+output blended)
    private let pricing: [String: Double] = [
        "gemini": 0.0005,   // Gemini 2.5 Flash
        "claude": 0.003,    // Claude Sonnet
        "openai": 0.0003,   // GPT-4o Mini
        "ollama": 0.0,      // Free (local)
        "local":  0.0       // Free (on-device)
    ]

    init() {
        loadRecords()
        refreshStats()
    }

    /// Record an API call.
    func recordCall(providerId: String, estimatedTokens: Int) {
        let costPer1K = pricing[providerId] ?? 0.0
        let cost = Double(estimatedTokens) / 1000.0 * costPer1K

        let record = UsageRecord(
            providerId: providerId,
            timestamp: Date(),
            estimatedTokens: estimatedTokens,
            estimatedCost: cost
        )
        records.append(record)
        saveRecords()
        refreshStats()
    }

    /// Get cost summary for a date range.
    func costSummary(from startDate: Date, to endDate: Date = Date()) -> Double {
        records
            .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
            .reduce(0) { $0 + $1.estimatedCost }
    }

    func callCount(from startDate: Date, to endDate: Date = Date()) -> Int {
        records.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }.count
    }

    // MARK: - Private

    private func refreshStats() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todayRecords = records.filter { $0.timestamp >= startOfDay }

        todayCalls = todayRecords.count
        todayCost = todayRecords.reduce(0) { $0 + $1.estimatedCost }

        var breakdown: [String: (calls: Int, cost: Double)] = [:]
        for record in todayRecords {
            let existing = breakdown[record.providerId] ?? (calls: 0, cost: 0.0)
            breakdown[record.providerId] = (calls: existing.calls + 1, cost: existing.cost + record.estimatedCost)
        }
        perProviderToday = breakdown
    }

    private func saveRecords() {
        // Keep only last 30 days of records
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        records = records.filter { $0.timestamp >= cutoff }

        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([UsageRecord].self, from: data) else { return }
        records = decoded
    }
}


struct KeychainHelper {
    private static let serviceName = Bundle.main.bundleIdentifier ?? "com.clippy.app"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first to avoid duplicates
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
