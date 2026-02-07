import XCTest
@testable import Clippy

final class CircuitBreakerTests: XCTestCase {

    // MARK: - Closed State

    func testClosedStateAllowsRequests() async {
        let cb = CircuitBreaker(name: "test", failureThreshold: 3, resetTimeout: 1)
        let canExecute = await cb.canExecute
        XCTAssertTrue(canExecute)
    }

    func testStartsInClosedState() async {
        let cb = CircuitBreaker(name: "test")
        let state = await cb.state
        XCTAssertEqual(String(describing: state), "closed")
    }

    // MARK: - Opening Circuit

    func testOpensAfterThresholdFailures() async {
        let cb = CircuitBreaker(name: "test", failureThreshold: 3, resetTimeout: 60)

        await cb.recordFailure()
        await cb.recordFailure()
        // Still closed after 2 failures
        var canExecute = await cb.canExecute
        XCTAssertTrue(canExecute)

        await cb.recordFailure()
        // Now open after 3 failures
        canExecute = await cb.canExecute
        XCTAssertFalse(canExecute)
    }

    func testRejectsInOpenState() async {
        let cb = CircuitBreaker(name: "test", failureThreshold: 2, resetTimeout: 60)

        await cb.recordFailure()
        await cb.recordFailure()

        // Should reject
        let canExecute = await cb.canExecute
        XCTAssertFalse(canExecute)
    }

    // MARK: - Half-Open State

    func testTransitionsToHalfOpenAfterTimeout() async {
        let cb = CircuitBreaker(name: "test", failureThreshold: 1, resetTimeout: 0.1)

        await cb.recordFailure()

        // Should be open immediately
        var canExecute = await cb.canExecute
        XCTAssertFalse(canExecute)

        // Wait for reset timeout
        try? await Task.sleep(for: .seconds(0.2))

        // Should transition to half-open and allow a request
        canExecute = await cb.canExecute
        XCTAssertTrue(canExecute)

        let state = await cb.state
        XCTAssertEqual(String(describing: state), "halfOpen")
    }

    // MARK: - Reset on Success

    func testResetsToClosedOnSuccessInHalfOpen() async {
        let cb = CircuitBreaker(name: "test", failureThreshold: 1, resetTimeout: 0.1)

        await cb.recordFailure()
        try? await Task.sleep(for: .seconds(0.2))

        // Trigger half-open
        _ = await cb.canExecute

        // Record success
        await cb.recordSuccess()

        let state = await cb.state
        XCTAssertEqual(String(describing: state), "closed")
    }

    // MARK: - Execute Method

    func testExecuteSucceeds() async throws {
        let cb = CircuitBreaker(name: "test", failureThreshold: 3, resetTimeout: 60)
        let result = try await cb.execute { return 42 }
        XCTAssertEqual(result, 42)
    }

    func testExecuteThrowsWhenOpen() async {
        let cb = CircuitBreaker(name: "test", failureThreshold: 1, resetTimeout: 60)
        await cb.recordFailure()

        do {
            _ = try await cb.execute { return 42 }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is CircuitBreakerError)
        }
    }

    func testExecuteRecordsFailureOnThrow() async {
        let cb = CircuitBreaker(name: "test", failureThreshold: 2, resetTimeout: 60)

        do {
            _ = try await cb.execute { () -> Int in throw CircuitBreakerError.circuitOpen }
        } catch {}

        // One failure recorded, still should be able to execute
        let canExecute = await cb.canExecute
        XCTAssertTrue(canExecute)

        do {
            _ = try await cb.execute { () -> Int in throw CircuitBreakerError.circuitOpen }
        } catch {}

        // Two failures, circuit should be open now
        let canExecuteAfter = await cb.canExecute
        XCTAssertFalse(canExecuteAfter)
    }

    // MARK: - Error

    func testCircuitBreakerErrorDescription() {
        let error = CircuitBreakerError.circuitOpen
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("unavailable"))
    }
}
