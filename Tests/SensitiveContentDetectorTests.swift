import XCTest
@testable import Clippy

final class SensitiveContentDetectorTests: XCTestCase {

    // MARK: - API Key Detection

    func testDetectsOpenAIKey() {
        let content = "My key is sk-abc123defg456hijklmnopqrst"
        XCTAssertTrue(SensitiveContentDetector.containsAPIKey(content))
    }

    func testDetectsAWSAccessKey() {
        let content = "AWS_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE"
        XCTAssertTrue(SensitiveContentDetector.containsAPIKey(content))
    }

    func testDetectsGitHubPAT() {
        let content = "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        XCTAssertTrue(SensitiveContentDetector.containsAPIKey(content))
    }

    func testDetectsGoogleAPIKey() {
        let content = "AIzaSyA1234567890abcdefghijklmnopqrstuvw"
        XCTAssertTrue(SensitiveContentDetector.containsAPIKey(content))
    }

    func testDetectsSlackToken() {
        let content = "SLACK_TOKEN=xoxb-123456789012-abcdefghij"
        XCTAssertTrue(SensitiveContentDetector.containsAPIKey(content))
    }

    func testDetectsStripeSecretKey() {
        // Use a generic key pattern that matches Stripe format without triggering push protection
        let content = "stripe_key=sk_live_" + String(repeating: "x", count: 24)
        XCTAssertTrue(SensitiveContentDetector.containsAPIKey(content))
    }

    func testDoesNotFlagNormalTextAsAPIKey() {
        let content = "This is a normal sentence about programming."
        XCTAssertFalse(SensitiveContentDetector.containsAPIKey(content))
    }

    // MARK: - Credit Card Detection

    func testDetectsValidVisaCard() {
        // 4111111111111111 passes Luhn check
        let content = "Card: 4111 1111 1111 1111"
        XCTAssertTrue(SensitiveContentDetector.containsCreditCard(content))
    }

    func testDetectsValidMastercardCard() {
        // 5500000000000004 passes Luhn check
        let content = "Pay with 5500 0000 0000 0004"
        XCTAssertTrue(SensitiveContentDetector.containsCreditCard(content))
    }

    func testRejectsInvalidLuhnNumber() {
        // 4111111111111112 fails Luhn check
        let content = "Card: 4111 1111 1111 1112"
        XCTAssertFalse(SensitiveContentDetector.containsCreditCard(content))
    }

    func testDoesNotFlagShortNumberAsCreditCard() {
        let content = "Order #12345"
        XCTAssertFalse(SensitiveContentDetector.containsCreditCard(content))
    }

    // MARK: - SSN Detection

    func testDetectsSSNWithDashes() {
        let content = "SSN: 123-45-6789"
        XCTAssertTrue(SensitiveContentDetector.containsSSN(content))
    }

    func testDetectsSSNWithSpaces() {
        let content = "SSN: 123 45 6789"
        XCTAssertTrue(SensitiveContentDetector.containsSSN(content))
    }

    func testDoesNotFlagRandomNumbersAsSSN() {
        let content = "Phone: 5551234567"
        XCTAssertFalse(SensitiveContentDetector.containsSSN(content))
    }

    // MARK: - Private Key Detection

    func testDetectsRSAPrivateKey() {
        let content = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpA..."
        XCTAssertTrue(SensitiveContentDetector.containsPrivateKey(content))
    }

    func testDetectsGenericPrivateKey() {
        let content = "-----BEGIN PRIVATE KEY-----\nMIIEvQ..."
        XCTAssertTrue(SensitiveContentDetector.containsPrivateKey(content))
    }

    func testDetectsPGPPrivateKey() {
        let content = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nVersion: ..."
        XCTAssertTrue(SensitiveContentDetector.containsPrivateKey(content))
    }

    func testDoesNotFlagPublicKeyAsPrivate() {
        let content = "-----BEGIN PUBLIC KEY-----\nMIIBIjA..."
        XCTAssertFalse(SensitiveContentDetector.containsPrivateKey(content))
    }

    // MARK: - Password Detection

    func testDetectsPasswordWithColon() {
        let content = "password: MyS3cur3P@ss"
        XCTAssertTrue(SensitiveContentDetector.containsPassword(content))
    }

    func testDetectsPasswordWithEquals() {
        let content = "PASSWORD=hunter2"
        XCTAssertTrue(SensitiveContentDetector.containsPassword(content))
    }

    func testDetectsSecretKey() {
        let content = "secret_key: abc123xyz"
        XCTAssertTrue(SensitiveContentDetector.containsPassword(content))
    }

    func testDoesNotFlagWordPasswordInSentence() {
        // "password" without a colon/equals and value should not match
        let content = "Please reset your password"
        XCTAssertFalse(SensitiveContentDetector.containsPassword(content))
    }

    // MARK: - Combined isSensitive

    func testIsSensitiveReturnsTrueForAPIKey() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("sk-abc123defg456hijklmnopqrst"))
    }

    func testIsSensitiveReturnsFalseForNormalText() {
        XCTAssertFalse(SensitiveContentDetector.isSensitive("Hello, world! This is just normal text."))
    }

    func testIsSensitiveWithEmptyString() {
        XCTAssertFalse(SensitiveContentDetector.isSensitive(""))
    }

    func testIsSensitiveWithVeryLongNormalString() {
        let longString = String(repeating: "This is a normal sentence. ", count: 500)
        XCTAssertFalse(SensitiveContentDetector.isSensitive(longString))
    }
}
