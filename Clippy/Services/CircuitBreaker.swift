import Foundation
import os

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

    /// Execute a closure through the circuit breaker.
    func execute<T>(_ operation: () async throws -> T) async throws -> T {
        guard canExecute else {
            throw CircuitBreakerError.circuitOpen
        }

        do {
            let result = try await operation()
            recordSuccess()
            return result
        } catch {
            recordFailure()
            throw error
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
