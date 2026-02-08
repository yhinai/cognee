import XCTest
@testable import Clippy

final class ActionDetectorTests: XCTestCase {

    let detector = ActionDetector.shared

    // MARK: - URL Detection

    func testDetectsHTTPSUrl() {
        let actions = detector.detectActions(in: "Visit https://www.apple.com for more")
        XCTAssertTrue(actions.contains(where: {
            if case .openURL(let url) = $0 { return url.absoluteString.contains("apple.com") }
            return false
        }))
    }

    func testDetectsHTTPUrl() {
        let actions = detector.detectActions(in: "Check http://example.com")
        XCTAssertTrue(actions.contains(where: {
            if case .openURL = $0 { return true }
            return false
        }))
    }

    // MARK: - Phone Number Detection

    func testDetectsPhoneNumber() {
        let actions = detector.detectActions(in: "Call me at (555) 123-4567")
        XCTAssertTrue(actions.contains(where: {
            if case .callNumber = $0 { return true }
            return false
        }))
    }

    func testDetectsInternationalPhoneNumber() {
        let actions = detector.detectActions(in: "Contact: +1-555-987-6543")
        XCTAssertTrue(actions.contains(where: {
            if case .callNumber = $0 { return true }
            return false
        }))
    }

    // MARK: - Date / Calendar Detection

    func testDetectsDate() {
        let actions = detector.detectActions(in: "Meeting on January 15, 2025 at 3pm")
        XCTAssertTrue(actions.contains(where: {
            if case .createEvent = $0 { return true }
            return false
        }))
    }

    // MARK: - Address Detection

    func testDetectsAddress() {
        let actions = detector.detectActions(in: "Office at 1 Infinite Loop, Cupertino, CA 95014")
        XCTAssertTrue(actions.contains(where: {
            if case .openMaps = $0 { return true }
            return false
        }))
    }

    // MARK: - No Actions

    func testNoActionsForPlainText() {
        let actions = detector.detectActions(in: "Just a normal sentence about nothing actionable")
        // Plain text with no URLs, dates, phones, or addresses
        XCTAssertTrue(actions.isEmpty)
    }

    func testNoActionsForEmptyString() {
        let actions = detector.detectActions(in: "")
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Limits

    func testLimitsToThreeActions() {
        // Text with multiple URLs should be capped at 3 actions
        let text = """
        https://one.com https://two.com https://three.com https://four.com https://five.com
        """
        let actions = detector.detectActions(in: text)
        XCTAssertLessThanOrEqual(actions.count, 3)
    }

    // MARK: - ClipboardAction Properties

    func testOpenURLActionProperties() {
        let action = ClipboardAction.openURL(URL(string: "https://example.com")!)
        XCTAssertEqual(action.iconName, "safari")
        XCTAssertEqual(action.label, "Open Link")
        XCTAssertFalse(action.id.isEmpty)
    }

    func testCallNumberActionProperties() {
        let action = ClipboardAction.callNumber("555-1234")
        XCTAssertEqual(action.iconName, "phone.fill")
        XCTAssertEqual(action.label, "Call")
    }

    func testEmailActionProperties() {
        let action = ClipboardAction.emailTo("test@example.com")
        XCTAssertEqual(action.iconName, "envelope.fill")
        XCTAssertEqual(action.label, "Email")
    }

    func testOpenMapsActionProperties() {
        let action = ClipboardAction.openMaps("1 Infinite Loop")
        XCTAssertEqual(action.iconName, "map")
        XCTAssertEqual(action.label, "Open Maps")
    }
}
