import AppKit
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

struct DiagnosticExporter {

    /// Collect system diagnostics (no user content) and format as plain text
    @MainActor
    static func collectDiagnostics(itemCount: Int, aiService: AIServiceType, lastError: String?) -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let memoryUsageMB = currentMemoryUsageMB()
        let uptime = ProcessInfo.processInfo.systemUptime

        let hasAccessibility = AXIsProcessTrusted()

        var lines: [String] = []
        lines.append("=== Clippy Diagnostics ===")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("-- App --")
        lines.append("Version: \(appVersion) (\(buildNumber))")
        lines.append("AI Service: \(aiService.description)")
        lines.append("Item Count: \(itemCount)")
        lines.append("")
        lines.append("-- System --")
        lines.append("macOS: \(osVersion)")
        lines.append("Memory Usage: \(memoryUsageMB) MB")
        lines.append("System Uptime: \(formatUptime(uptime))")
        lines.append("")
        lines.append("-- Permissions --")
        lines.append("Accessibility: \(hasAccessibility ? "Granted" : "NOT Granted")")
        lines.append("")
        lines.append("-- Errors --")
        lines.append("Last Error: \(lastError ?? "None")")
        lines.append("")
        lines.append("=== End Diagnostics ===")

        return lines.joined(separator: "\n")
    }

    /// Copy diagnostics string to clipboard
    @MainActor
    static func copyDiagnosticsToClipboard(itemCount: Int, aiService: AIServiceType, lastError: String?) {
        let text = collectDiagnostics(itemCount: itemCount, aiService: aiService, lastError: lastError)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Logger.services.info("Diagnostics copied to clipboard")
    }

    private static func currentMemoryUsageMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}
