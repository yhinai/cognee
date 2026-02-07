import Foundation
import os

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
