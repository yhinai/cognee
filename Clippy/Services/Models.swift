import AppKit
import Foundation
import SwiftData
import SwiftUI

// MARK: - AI Service Type

enum AIServiceType: String, CaseIterable {
    case gemini = "Gemini"
    case local = "Local AI"
    case claude = "Claude"
    case openai = "OpenAI"
    case ollama = "Ollama"
    case backend = "Backend (Cognee+Qdrant)"

    var description: String {
        switch self {
        case .gemini:
            return "Gemini 2.5 Flash (Cloud)"
        case .local:
            return "Local Qwen3-4b (On-device)"
        case .claude:
            return "Claude Sonnet 4.5 (Cloud)"
        case .openai:
            return "GPT-4o Mini (Cloud)"
        case .ollama:
            return "Ollama (Local)"
        case .backend:
            return "Backend: Cognee + Qdrant + SLM"
        }
    }
}

// MARK: - Item Model

@Model
final class Item {
    var timestamp: Date
    var content: String
    var title: String? // Added for structured content (e.g., Vision titles)
    var appName: String?
    var contentType: String
    var usageCount: Int
    var vectorId: UUID?
    var tags: [String] // AI-generated semantic tags for better retrieval
    var imagePath: String? // Path to saved image file (for image clipboard items)
    var isFavorite: Bool = false

    /// Optional expiry date for auto-cleanup (e.g., sensitive items expire after 1 hour)
    var expiresAt: Date?

    /// Persisted sensitive content flag, set at save time to avoid re-computing each render
    var isSensitiveFlag: Bool = false

    /// Cached result of sensitive content detection (not persisted).
    @Transient var _sensitiveCache: Bool?

    /// True if content matches sensitive patterns (API keys, credit cards, SSNs, etc.)
    /// Reads from persisted `isSensitiveFlag` first, then falls back to runtime detection.
    var isSensitive: Bool {
        if isSensitiveFlag { return true }
        if let cached = _sensitiveCache { return cached }
        let result = SensitiveContentDetector.isSensitive(content)
        _sensitiveCache = result
        return result
    }

    init(timestamp: Date, content: String = "", title: String? = nil, appName: String? = nil, contentType: String = "text", imagePath: String? = nil, isFavorite: Bool = false, expiresAt: Date? = nil, isSensitiveFlag: Bool = false) {
        self.timestamp = timestamp
        self.content = content
        self.title = title
        self.appName = appName
        self.contentType = contentType
        self.usageCount = 0
        self.tags = []
        self.imagePath = imagePath
        self.isFavorite = isFavorite
        self.expiresAt = expiresAt
        self.isSensitiveFlag = isSensitiveFlag
    }
}

// MARK: - Input Mode

/// Represents the active input capture mode for the assistant
enum InputMode {
    case none
    case textCapture // Option+X
    case voiceCapture // Option+Space
    case visionCapture // Option+V
}

// MARK: - Clippy Animation State

/// Represents the different animation states for the Clippy character
enum ClippyAnimationState {
    case idle      // User pressed Option+X, waiting for input
    case writing   // User is typing text
    case thinking  // AI is processing the query (minimum 3 seconds)
    case done      // AI has completed processing
    case error     // An error occurred (API failure, etc.)
    
    /// The GIF file name for this animation state
    var gifFileName: String {
        switch self {
        case .idle:
            return "clippy-idle"
        case .writing:
            return "clippy-writing"
        case .thinking:
            return "clippy-thinking"
        case .done:
            return "clippy-done"
        case .error:
            return "clippy-idle" // Use idle animation for errors
        }
    }
    
    /// Default message to display for this state
    var defaultMessage: String {
        switch self {
        case .idle:
            return "Listening..."
        case .writing:
            return "Got it..."
        case .thinking:
            return "Thinking..."
        case .done:
            return "Done!"
        case .error:
            return "Oops! Something went wrong"
        }
    }
}

// MARK: - Item Helpers (shared across views)

extension Item {
    var isCodeContent: Bool {
        if contentType == "code" { return true }
        let codeKeywords = ["func ", "class ", "struct ", "import ", "var ", "let ", "def ", "return "]
        let hasKeywords = codeKeywords.contains(where: { content.contains($0) })
        let hasBraces = content.contains("{") && content.contains("}")
        return hasKeywords && hasBraces
    }

    var isURLContent: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    var iconSystemName: String {
        if isSensitive { return "lock.fill" }
        if isCodeContent { return "chevron.left.forwardslash.chevron.right" }
        if isURLContent { return "link" }
        switch contentType {
        case "image": return "photo"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }

    var iconGradient: LinearGradient {
        if isSensitive {
            return LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if isCodeContent {
            return LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if isURLContent {
            return LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        switch contentType {
        case "image":
            return LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "code":
            return LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Shared Utilities

enum PasteHelper {
    /// Simulate Cmd+V via CGEvent (used by search overlay and content view).
    static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
        }
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
        }
    }
}
