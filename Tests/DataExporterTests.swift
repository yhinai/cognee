import XCTest
@testable import Clippy

final class DataExporterTests: XCTestCase {

    // MARK: - Export

    func testExportProducesValidJSON() throws {
        let item = Item(
            timestamp: Date(),
            content: "test content",
            title: "Test Title",
            appName: "Xcode",
            contentType: "text",
            isFavorite: true
        )
        item.tags = ["swift", "code"]

        guard let data = DataExporter.exportItems([item]) else {
            XCTFail("Export returned nil")
            return
        }

        // Verify it's valid JSON
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertNotNil(json?["exportDate"])

        let items = json?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?["content"] as? String, "test content")
        XCTAssertEqual(items?.first?["title"] as? String, "Test Title")
    }

    func testExportEmptyArray() {
        guard let data = DataExporter.exportItems([]) else {
            XCTFail("Export returned nil for empty array")
            return
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 0)
    }

    func testExportMultipleItems() {
        let items = [
            Item(timestamp: Date(), content: "item 1"),
            Item(timestamp: Date(), content: "item 2"),
            Item(timestamp: Date(), content: "item 3"),
        ]

        guard let data = DataExporter.exportItems(items) else {
            XCTFail("Export returned nil")
            return
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let exported = json?["items"] as? [[String: Any]]
        XCTAssertEqual(exported?.count, 3)
    }

    // MARK: - Backup Format

    func testBackupDecodesCorrectly() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2025-01-15T10:00:00Z",
            "items": [{
                "content": "hello",
                "title": null,
                "appName": "Safari",
                "contentType": "text",
                "tags": ["web"],
                "timestamp": "2025-01-15T09:00:00Z",
                "isFavorite": false,
                "imagePath": null
            }]
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let backup = try decoder.decode(ClippyBackup.self, from: data)
        XCTAssertEqual(backup.version, 1)
        XCTAssertEqual(backup.items.count, 1)
        XCTAssertEqual(backup.items[0].content, "hello")
        XCTAssertEqual(backup.items[0].tags, ["web"])
    }

    func testBackupHandlesExtraFields() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2025-01-15T10:00:00Z",
            "items": [],
            "unknownField": "should be ignored"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Should not throw even with extra fields
        let backup = try decoder.decode(ClippyBackup.self, from: data)
        XCTAssertEqual(backup.version, 1)
    }

    func testExportPreservesImagePathAsFilename() {
        let item = Item(
            timestamp: Date(),
            content: "screenshot",
            contentType: "image",
            imagePath: "/Users/test/Library/Clippy/Images/abc123.png"
        )

        guard let data = DataExporter.exportItems([item]) else {
            XCTFail("Export returned nil")
            return
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["items"] as? [[String: Any]]
        // Should export only the filename, not full path
        XCTAssertEqual(items?.first?["imagePath"] as? String, "abc123.png")
    }
}
