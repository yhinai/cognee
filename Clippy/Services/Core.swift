import Foundation
import os

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
