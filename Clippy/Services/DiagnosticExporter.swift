import Foundation
import AppKit
import os

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
