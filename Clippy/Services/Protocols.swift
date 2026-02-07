import Foundation
import SwiftData

// MARK: - Vector Search Protocol

@MainActor
protocol VectorSearching {
    var isInitialized: Bool { get }
    func initialize() async
    func addDocument(vectorId: UUID, text: String) async
    func addDocuments(items: [(UUID, String)]) async
    func search(query: String, limit: Int) async -> [(UUID, Float)]
    func deleteDocument(vectorId: UUID) async throws
}

// MARK: - Clipboard Monitoring Protocol

@MainActor
protocol ClipboardMonitoring: AnyObject, ObservableObject {
    var clipboardContent: String { get }
    var isMonitoring: Bool { get }
    var skipNextClipboardChange: Bool { get set }
    func startMonitoring(repository: ClipboardRepository, contextEngine: ContextEngine, geminiService: GeminiService?, localAIService: LocalAIService?, backendService: BackendService?)
    func stopMonitoring()
}

// MARK: - Context Providing Protocol

@MainActor
protocol ContextProviding: AnyObject {
    var currentAppName: String { get }
    var currentWindowTitle: String { get }
    var hasAccessibilityPermission: Bool { get }
    func updateContext()
    func getRichContext(clipboardContent: String) -> String
}
