import XCTest
@testable import Clippy

final class DevTransformsTests: XCTestCase {

    let registry = TransformRegistry.shared

    // MARK: - Base64

    func testBase64EncodeDecodeRoundtrip() {
        let original = "Hello, World!"
        let encode = findTransform("base64_encode")
        let decode = findTransform("base64_decode")
        let encoded = encode.transform(original)
        let decoded = decode.transform(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase64EncodeOutput() {
        let encode = findTransform("base64_encode")
        XCTAssertEqual(encode.transform("Hello"), "SGVsbG8=")
    }

    func testBase64DecodeInvalidInput() {
        let decode = findTransform("base64_decode")
        let result = decode.transform("not-valid-base64!!!")
        XCTAssertEqual(result, "[Invalid Base64]")
    }

    // MARK: - URL Encoding

    func testURLEncodeDecodeRoundtrip() {
        let original = "hello world&foo=bar"
        let encode = findTransform("url_encode")
        let decode = findTransform("url_decode")
        let encoded = encode.transform(original)
        XCTAssertFalse(encoded.contains(" "))
        let decoded = decode.transform(encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - JSON Formatting

    func testJSONPrettyPrint() {
        let compact = "{\"name\":\"test\",\"value\":42}"
        let pretty = findTransform("json_pretty")
        let result = pretty.transform(compact)
        XCTAssertTrue(result.contains("\n"))
        XCTAssertTrue(result.contains("  "))
    }

    func testJSONMinify() {
        let pretty = "{\n  \"name\": \"test\",\n  \"value\": 42\n}"
        let minify = findTransform("json_minify")
        let result = minify.transform(pretty)
        XCTAssertFalse(result.contains("\n"))
        XCTAssertTrue(result.contains("\"name\""))
    }

    func testJSONPrettyPrintInvalidJSON() {
        let invalid = "not json"
        let pretty = findTransform("json_pretty")
        XCTAssertEqual(pretty.transform(invalid), "[Invalid JSON]")
    }

    // MARK: - Case Conversion

    func testCamelToSnakeCase() {
        let transform = findTransform("camel_to_snake")
        XCTAssertEqual(transform.transform("myVariableName"), "my_variable_name")
    }

    func testSnakeToCamelCase() {
        let transform = findTransform("snake_to_camel")
        XCTAssertEqual(transform.transform("my_variable_name"), "myVariableName")
    }

    // MARK: - SHA-256

    func testSHA256KnownHash() {
        let transform = findTransform("sha256")
        let result = transform.transform("hello")
        // Known SHA-256 of "hello"
        XCTAssertEqual(result, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    // MARK: - Line Operations

    func testSortLines() {
        let transform = findTransform("sort_lines")
        let result = transform.transform("cherry\napple\nbanana")
        XCTAssertEqual(result, "apple\nbanana\ncherry")
    }

    func testDeduplicateLines() {
        let transform = findTransform("dedup_lines")
        let result = transform.transform("a\nb\na\nc\nb")
        XCTAssertEqual(result, "a\nb\nc")
    }

    // MARK: - Extract

    func testExtractURLs() {
        let transform = findTransform("extract_urls")
        let result = transform.transform("Visit https://example.com and http://test.org for more")
        XCTAssertTrue(result.contains("https://example.com"))
        XCTAssertTrue(result.contains("http://test.org"))
    }

    func testExtractEmailsFromText() {
        let transform = findTransform("extract_emails")
        let result = transform.transform("Contact john@example.com or jane@test.org")
        XCTAssertTrue(result.contains("john@example.com"))
        XCTAssertTrue(result.contains("jane@test.org"))
    }

    func testExtractURLsNoURLs() {
        let transform = findTransform("extract_urls")
        let result = transform.transform("No links here")
        XCTAssertEqual(result, "[No URLs found]")
    }

    // MARK: - Text Stats

    func testCountStats() {
        let transform = findTransform("count_stats")
        let result = transform.transform("hello world\nfoo bar")
        XCTAssertTrue(result.contains("Lines: 2"))
        XCTAssertTrue(result.contains("Words: 4"))
    }

    // MARK: - Empty String

    func testTrimWhitespace() {
        let transform = findTransform("trim")
        XCTAssertEqual(transform.transform("  hello  "), "hello")
    }

    func testEmptyStringBase64() {
        let encode = findTransform("base64_encode")
        let result = encode.transform("")
        XCTAssertEqual(result, "") // Base64 of empty string is empty string
    }

    // MARK: - Registry

    func testRegistryHasAllCategories() {
        for category in TransformCategory.allCases {
            let transforms = registry.transforms(for: category)
            XCTAssertFalse(transforms.isEmpty, "Category \(category.rawValue) should have transforms")
        }
    }

    // MARK: - Helpers

    private func findTransform(_ id: String) -> TextTransform {
        registry.transforms.first(where: { $0.id == id })!
    }
}
