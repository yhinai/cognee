import XCTest
@testable import Clippy

final class GeminiResponseParsingTests: XCTestCase {

    // MARK: - GeminiAPIResponse Decoding

    func testDecodesValidResponse() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "parts": [{"text": "{\\"A\\": \\"hello\\", \\"paste_image\\": 0}"}],
                    "role": "model"
                },
                "finishReason": "STOP"
            }]
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)

        XCTAssertNotNil(response.candidates)
        XCTAssertEqual(response.candidates?.count, 1)

        let text = response.candidates?.first?.content?.parts?.first?.text
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("hello"))
    }

    func testDecodesEmptyCandidates() throws {
        let json = """
        {"candidates": []}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)

        XCTAssertEqual(response.candidates?.count, 0)
    }

    func testDecodesNullCandidates() throws {
        let json = """
        {}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)

        XCTAssertNil(response.candidates)
    }

    func testDecodesResponseWithNoParts() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "parts": [],
                    "role": "model"
                },
                "finishReason": "STOP"
            }]
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)

        let text = response.candidates?.first?.content?.parts?.first?.text
        XCTAssertNil(text)
    }

    func testDecodesResponseWithNullText() throws {
        let json = """
        {
            "candidates": [{
                "content": {
                    "parts": [{"text": null}],
                    "role": "model"
                },
                "finishReason": "STOP"
            }]
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)

        let text = response.candidates?.first?.content?.parts?.first?.text
        XCTAssertNil(text)
    }

    // MARK: - Answer JSON Parsing

    func testParsesTextAnswer() throws {
        let responseText = """
        {"A": "john@example.com", "paste_image": 0}
        """
        let data = responseText.data(using: .utf8)!
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let answer = (jsonObject["A"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasteImage = jsonObject["paste_image"] as? Int

        XCTAssertEqual(answer, "john@example.com")
        XCTAssertEqual(pasteImage, 0)
    }

    func testParsesImagePasteRequest() throws {
        let responseText = """
        {"A": "", "paste_image": 3}
        """
        let data = responseText.data(using: .utf8)!
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let answer = jsonObject["A"] as? String
        let pasteImage = jsonObject["paste_image"] as? Int

        XCTAssertEqual(answer, "")
        XCTAssertEqual(pasteImage, 3)
    }

    func testHandlesMalformedJSON() {
        let responseText = "not valid json at all"
        let data = responseText.data(using: .utf8)!
        let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(jsonObject)
    }

    // MARK: - Tag Response Parsing

    func testParsesTagResponse() throws {
        let responseText = """
        {"tags": ["swift", "code", "function"]}
        """
        let data = responseText.data(using: .utf8)!
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tagsArray = jsonObject["tags"] as! [String]

        let tags = tagsArray.map { $0.lowercased() }.filter { !$0.isEmpty }
        XCTAssertEqual(tags, ["swift", "code", "function"])
    }

    func testParsesEmptyTagResponse() throws {
        let responseText = """
        {"tags": []}
        """
        let data = responseText.data(using: .utf8)!
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tagsArray = jsonObject["tags"] as! [String]

        XCTAssertTrue(tagsArray.isEmpty)
    }

    // MARK: - Markdown JSON Cleaning

    func testCleansMarkdownWrappedJSON() {
        let wrapped = "```json\n{\"A\": \"test\", \"paste_image\": 0}\n```"
        var cleaned = wrapped
        if cleaned.contains("```json") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(cleaned, "{\"A\": \"test\", \"paste_image\": 0}")
    }

    func testCleansGenericCodeFenceJSON() {
        let wrapped = "```\n{\"tags\": [\"hello\"]}\n```"
        var cleaned = wrapped
        if cleaned.contains("```json") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        } else if cleaned.contains("```") {
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(cleaned, "{\"tags\": [\"hello\"]}")
    }

    func testCleanPassesThroughPlainJSON() {
        let plain = "{\"A\": \"value\", \"paste_image\": 0}"
        var cleaned = plain
        if cleaned.contains("```json") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        } else if cleaned.contains("```") {
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(cleaned, plain)
    }
}
