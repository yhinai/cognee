import Foundation
import SwiftData
import os

// MARK: - Backup Format

struct ClippyBackup: Codable {
    let version: Int
    let exportDate: Date
    let items: [BackupItem]

    static let currentVersion = 1

    struct BackupItem: Codable {
        let content: String
        let title: String?
        let appName: String?
        let contentType: String
        let tags: [String]
        let timestamp: Date
        let isFavorite: Bool
        let imagePath: String? // Filename only (not full path)
    }
}

// MARK: - Data Exporter

struct DataExporter {

    /// Export items to JSON data
    static func exportItems(_ items: [Item]) -> Data? {
        let backupItems = items.map { item in
            ClippyBackup.BackupItem(
                content: item.content,
                title: item.title,
                appName: item.appName,
                contentType: item.contentType,
                tags: item.tags,
                timestamp: item.timestamp,
                isFavorite: item.isFavorite,
                imagePath: item.imagePath.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
            )
        }

        let backup = ClippyBackup(
            version: ClippyBackup.currentVersion,
            exportDate: Date(),
            items: backupItems
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(backup)
            Logger.services.info("Exported \(items.count, privacy: .public) items (\(data.count, privacy: .public) bytes)")
            return data
        } catch {
            Logger.services.error("Export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Import items from JSON data into the given model context
    @MainActor
    static func importItems(from data: Data, into context: ModelContext) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let backup = try decoder.decode(ClippyBackup.self, from: data)
            Logger.services.info("Importing backup v\(backup.version, privacy: .public) with \(backup.items.count, privacy: .public) items")

            var imported = 0
            for backupItem in backup.items {
                let item = Item(
                    timestamp: backupItem.timestamp,
                    content: backupItem.content,
                    title: backupItem.title,
                    appName: backupItem.appName,
                    contentType: backupItem.contentType,
                    imagePath: backupItem.imagePath,
                    isFavorite: backupItem.isFavorite
                )
                item.tags = backupItem.tags
                item.vectorId = UUID()
                context.insert(item)
                imported += 1
            }

            try context.save()
            Logger.services.info("Successfully imported \(imported, privacy: .public) items")
            return imported
        } catch {
            Logger.services.error("Import failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
