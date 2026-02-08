import Foundation
import AppKit
import ApplicationServices

/// ContextEngine handles all Accessibility (AX) framework interactions.
/// Extracts window titles, focused elements, and builds rich context for AI queries.
@MainActor
class ContextEngine: ObservableObject {
    @Published var currentAppName: String = "Unknown"
    @Published var currentWindowTitle: String = ""
    @Published var accessibilityContext: String = ""
    @Published var hasAccessibilityPermission: Bool = false
    
    init() {
        checkAccessibilityPermission()
    }
    
    // MARK: - Permission Management
    
    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = accessEnabled
    }
    
    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Context Capture
    
    /// Update current app and window context
    func updateContext() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            currentAppName = "Unknown"
            currentWindowTitle = ""
            accessibilityContext = ""
            return
        }
        
        currentAppName = frontmostApp.localizedName ?? "Unknown App"
        
        if hasAccessibilityPermission {
            currentWindowTitle = getActiveWindowTitle() ?? ""
            accessibilityContext = buildAccessibilityContext(for: frontmostApp)
        } else {
            currentWindowTitle = frontmostApp.localizedName ?? ""
            accessibilityContext = "Accessibility permission not granted."
        }
    }
    
    /// Get the title of the currently focused window
    func getActiveWindowTitle() -> String? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        
        let pid = frontmostApp.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        
        var window: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        
        guard result == .success, let windowRef = window else { return nil }
        let windowElement = windowRef as! AXUIElement

        var title: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title)
        
        if titleResult == .success, let windowTitle = title as? String {
            return windowTitle
        }
        
        return nil
    }
    
    /// Build rich context from accessibility tree
    private func buildAccessibilityContext(for appInfo: NSRunningApplication) -> String {
        let pid = appInfo.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard windowResult == .success, let focusedWindowRef = focusedWindow else {
            return ""
        }
        let windowElement = focusedWindowRef as! AXUIElement
        var focusedUIElement: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedUIElement)
        var snapshotLines: [String] = []
        snapshotLines.append("App: \(currentAppName)")
        if let title = try? windowElement.attributeString(for: kAXTitleAttribute as CFString), !title.isEmpty {
            snapshotLines.append("Window: \(title)")
        }
        // Collect static labels for quick context
        let staticSummary = collectStaticTexts(from: windowElement, limit: 6)
        if !staticSummary.isEmpty {
            snapshotLines.append("Static Content: \(staticSummary)")
        }
        if let focusedRef = focusedUIElement {
            let focused = focusedRef as! AXUIElement
            snapshotLines.append("Focused Element:")
            var seenFocused = Set<String>()
            snapshotLines.append(contentsOf: describeElement(focused, depth: 1, maxDepth: 2, siblingsLimit: 4, dedupe: &seenFocused))
        }
        snapshotLines.append("Visible Elements:")
        var seen = Set<String>()
        snapshotLines.append(contentsOf: describeElement(windowElement, depth: 1, maxDepth: 2, siblingsLimit: 8, dedupe: &seen))
        return snapshotLines.joined(separator: "\n")
    }
    
    /// Collect static text content from UI elements
    private func collectStaticTexts(from root: AXUIElement, limit: Int) -> String {
        var queue: [AXUIElement] = [root]
        var collected: [String] = []
        var visited = Set<AXUIElementHash>()
        while !queue.isEmpty && collected.count < limit {
            let element = queue.removeFirst()
            let hash = AXUIElementHash(element)
            guard !visited.contains(hash) else { continue }
            visited.insert(hash)
            if let value = try? element.attributeString(for: kAXValueAttribute as CFString), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                if collected.count >= limit { break }
            } else if let title = try? element.attributeString(for: kAXTitleAttribute as CFString), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected.append(title.trimmingCharacters(in: .whitespacesAndNewlines))
                if collected.count >= limit { break }
            }
            queue.append(contentsOf: element.attributeArray(for: kAXChildrenAttribute as CFString, limit: nil))
        }
        return collected.joined(separator: " • ")
    }
    
    /// Build rich context string for semantic search
    func getRichContext(clipboardContent: String = "") -> String {
        var contextParts: [String] = []
        
        if !currentAppName.isEmpty && currentAppName != "Unknown" {
            contextParts.append("App: \(currentAppName)")
        }
        
        if !currentWindowTitle.isEmpty {
            contextParts.append("Window: \(currentWindowTitle)")
        }
        
        if !clipboardContent.isEmpty && clipboardContent.count < 200 {
            contextParts.append("Recent: \(clipboardContent.prefix(100))")
        }
        
        if hasAccessibilityPermission {
            let axSummary = accessibilityContext
                .split(separator: "\n")
                .prefix(6)
                .joined(separator: " ")
            if !axSummary.isEmpty {
                contextParts.append("Context: \(axSummary.prefix(300))")
            }
        }
        
        // Time of day context
        let hour = Calendar.current.component(.hour, from: Date())
        let timeContext = switch hour {
        case 5..<12: "morning work"
        case 12..<17: "afternoon work"
        case 17..<22: "evening work"
        default: "late night work"
        }
        contextParts.append(timeContext)
        
        return contextParts.joined(separator: " | ")
    }
    
    // MARK: - Element Description
    
    private func describeElement(_ element: AXUIElement, depth: Int, maxDepth: Int, siblingsLimit: Int, dedupe: inout Set<String>) -> [String] {
        guard depth <= maxDepth else { return [] }
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []

        let role = element.roleDescription()
        let title = (try? element.attributeString(for: kAXTitleAttribute as CFString)) ?? ""
        let value = element.valueDescription()
        let identifier = [role, title, value].joined(separator: "|")

        if !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !dedupe.contains(identifier) {
            dedupe.insert(identifier)
            let summary = [role, title, value]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            if !summary.isEmpty {
                lines.append("\(indent)• \(summary)")
            }
        }

        if depth == maxDepth { return lines }

        let children = element.attributeArray(for: kAXChildrenAttribute as CFString, limit: siblingsLimit)
        for child in children {
            lines.append(contentsOf: describeElement(child, depth: depth + 1, maxDepth: maxDepth, siblingsLimit: siblingsLimit, dedupe: &dedupe))
        }

        return lines
    }
}

// MARK: - AXUIElement Extensions

private extension AXUIElement {
    func attributeString(for attribute: CFString) throws -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, attribute, &value)
        if result == .success, let str = value as? String {
            return str
        }
        throw NSError(domain: "AXError", code: Int(result.rawValue), userInfo: [NSLocalizedDescriptionKey: "Accessibility error: \(result)"])
    }
    
    func attributeArray(for attribute: CFString, limit: Int? = nil) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, attribute, &value)
        guard result == .success, let arr = value as? [AXUIElement] else { return [] }
        if let limit, limit >= 0 {
            return Array(arr.prefix(limit))
        }
        return arr
    }
    
    func roleDescription() -> String {
        (try? attributeString(for: kAXRoleDescriptionAttribute as CFString)) ??
        (try? attributeString(for: kAXRoleAttribute as CFString)) ?? ""
    }
    
    func valueDescription() -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, kAXValueAttribute as CFString, &value)
        if result == .success {
            if let str = value as? String { return str }
            if let num = value as? NSNumber { return num.stringValue }
        }
        return ""
    }
}

// MARK: - AXUIElement Hash for Deduplication

private struct AXUIElementHash: Hashable {
    private let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element as CFTypeRef))
    }
    
    static func == (lhs: AXUIElementHash, rhs: AXUIElementHash) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
