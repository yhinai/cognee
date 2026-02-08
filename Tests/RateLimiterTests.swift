import XCTest
@testable import Clippy

final class RateLimiterTests: XCTestCase {

    // MARK: - Basic Acquisition

    func testAcquireSucceedsWithAvailableTokens() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 5, refillRate: 1)
        // Should return immediately since we have 5 tokens
        await limiter.acquire()
        // No assertion needed - if it returns, the test passes (no deadlock/hang)
    }

    func testCanAcquireUpToMaxTokens() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 3, refillRate: 1)
        // Acquire all 3 tokens without blocking
        await limiter.acquire()
        await limiter.acquire()
        await limiter.acquire()
        // Test passes if all three complete
    }

    // MARK: - Rate Limiting Under Load

    func testRateLimitsWhenTokensDepleted() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 2, refillRate: 10)

        // Deplete all tokens
        await limiter.acquire()
        await limiter.acquire()

        // This should take some time since tokens are depleted
        let start = Date()
        await limiter.acquire()
        let elapsed = Date().timeIntervalSince(start)

        // Should have waited at least a small amount for refill
        // With refillRate=10, 1 token refills in 0.1s
        XCTAssertGreaterThan(elapsed, 0.01)
    }

    // MARK: - Token Refill

    func testTokensRefillOverTime() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 2, refillRate: 100)

        // Deplete tokens
        await limiter.acquire()
        await limiter.acquire()

        // Wait for refill (100 tokens/sec = 0.01s per token)
        try? await Task.sleep(for: .seconds(0.05))

        // Should be able to acquire again quickly after refill
        let start = Date()
        await limiter.acquire()
        let elapsed = Date().timeIntervalSince(start)

        // Should be nearly instant since tokens had time to refill
        XCTAssertLessThan(elapsed, 0.1)
    }

    // MARK: - Concurrent Access

    func testConcurrentAccessDoesNotCrash() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 10, refillRate: 5)

        // Launch multiple concurrent tasks
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await limiter.acquire()
                }
            }
        }
        // Test passes if no crash or data race occurs
    }

    // MARK: - Initialization

    func testDefaultInitialization() async {
        // Default: maxTokens=10, refillRate=2
        let limiter = TokenBucketRateLimiter()

        // Should be able to acquire several tokens immediately
        for _ in 0..<5 {
            await limiter.acquire()
        }
    }
}
