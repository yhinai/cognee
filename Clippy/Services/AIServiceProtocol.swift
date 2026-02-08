import Foundation
import SwiftData

/// Unified protocol for AI services (Gemini, Local AI, etc.)
/// Allows the View layer to be agnostic of the underlying AI implementation.
@MainActor
protocol AIServiceProtocol: AnyObject, ObservableObject {
    var isProcessing: Bool { get }

    /// Generate an answer based on user question and clipboard context
    func generateAnswer(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) async -> String?

    /// Generate a streaming answer. Default wraps non-streaming response.
    func generateAnswerStream(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) -> AsyncThrowingStream<String, Error>

    /// Generate semantic tags for clipboard content
    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String]

    /// Analyze an image and return a description
    func analyzeImage(imageData: Data) async -> String?
}

// Default streaming implementation: wraps non-streaming response into a single-token stream
extension AIServiceProtocol {
    func generateAnswerStream(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if let response = await self.generateAnswer(
                    question: question,
                    clipboardContext: clipboardContext,
                    appName: appName
                ) {
                    continuation.yield(response)
                }
                continuation.finish()
            }
        }
    }
}

/// Shared type for RAG context items used by both AI services
struct RAGContextItem: Sendable {
    let content: String
    let tags: [String]
    let type: String
    let timestamp: Date
    let title: String?
    
    init(content: String, tags: [String], type: String = "text", timestamp: Date = Date(), title: String? = nil) {
        self.content = content
        self.tags = tags
        self.type = type
        self.timestamp = timestamp
        self.title = title
    }
}

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
