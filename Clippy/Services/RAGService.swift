import Foundation
import os

/// Native RAG (Retrieval-Augmented Generation) service for in-process Q&A.
/// Replaces the Python backend's `/ask` endpoint with pure Swift using MLX.
@MainActor
class RAGService: ObservableObject {
    @Published var isProcessing = false
    @Published var lastError: String?

    private weak var vectorSearch: VectorSearchService?
    private weak var localAI: LocalAIService?

    // Configuration
    private let contextLimit = 5

    init(vectorSearch: VectorSearchService?, localAI: LocalAIService?) {
        self.vectorSearch = vectorSearch
        self.localAI = localAI
    }

    // MARK: - Public API

    /// Ask a question using RAG. Uses search results directly without repository lookup.
    /// - Parameters:
    ///   - question: The user's question
    ///   - contextItems: Pre-built context items (typically from QueryOrchestrator)
    /// - Returns: A RAGAnswer with the question, answer, source count, model, and timing
    func ask(question: String, contextItems: [RAGContextItem] = []) async -> RAGAnswer {
        isProcessing = true
        defer { isProcessing = false }
        lastError = nil

        let startTime = Date()

        // If no context provided, try vector search
        var items = contextItems
        if items.isEmpty, let vectorSearch = vectorSearch {
            let searchResults = await vectorSearch.search(query: question, limit: contextLimit)
            if searchResults.isEmpty {
                return RAGAnswer(
                    question: question,
                    answer: "I couldn't find any relevant content in your clipboard history.",
                    sources: 0,
                    model: "local",
                    timeMs: Date().timeIntervalSince(startTime) * 1000
                )
            }
            // Note: Without repository lookup, we can only return a generic message
            // In practice, QueryOrchestrator should provide the contextItems
        }

        // Generate answer using local LLM
        guard let localAI = localAI else {
            lastError = "Local AI not available"
            return RAGAnswer(
                question: question,
                answer: "AI service unavailable.",
                sources: items.count,
                model: "none",
                timeMs: Date().timeIntervalSince(startTime) * 1000
            )
        }

        let answer = await localAI.generateAnswer(
            question: question,
            clipboardContext: items,
            appName: nil
        ) ?? "I couldn't generate an answer."

        let timeMs = Date().timeIntervalSince(startTime) * 1000

        return RAGAnswer(
            question: question,
            answer: answer,
            sources: items.count,
            model: "Qwen2.5-1.5B",
            timeMs: timeMs
        )
    }

    /// Simple text chunking for long documents (replaces Cognee's chunking).
    func chunkText(_ text: String, maxChunkSize: Int = 500, overlap: Int = 50) -> [String] {
        guard text.count > maxChunkSize else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[start..<end])
            chunks.append(chunk)

            // Move start forward, accounting for overlap
            let nextStart = text.index(start, offsetBy: maxChunkSize - overlap, limitedBy: text.endIndex)
            if let next = nextStart, next > start {
                start = next
            } else {
                break
            }
        }

        return chunks
    }
}

// MARK: - Models

struct RAGAnswer: Codable {
    let question: String
    let answer: String
    let sources: Int
    let model: String
    let timeMs: Double

    enum CodingKeys: String, CodingKey {
        case question, answer, sources, model
        case timeMs = "time_ms"
    }
}
