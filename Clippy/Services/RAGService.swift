import Foundation
import os

/// Native RAG (Retrieval-Augmented Generation) service for in-process Q&A.
/// Replaces the Python backend's `/ask` endpoint with pure Swift using MLX.
///
/// Note: Context items must be provided by the caller (e.g., QueryOrchestrator).
/// This service does not perform its own vector search - that's handled upstream.
@MainActor
class RAGService: ObservableObject {
    @Published var isProcessing = false
    @Published var lastError: String?

    private weak var localAI: LocalAIService?

    init(localAI: LocalAIService?) {
        self.localAI = localAI
    }

    // MARK: - Public API

    /// Ask a question using RAG with pre-built context items.
    /// - Parameters:
    ///   - question: The user's question
    ///   - contextItems: Pre-built context items from QueryOrchestrator (required)
    /// - Returns: A RAGAnswer with the question, answer, source count, model, and timing
    func ask(question: String, contextItems: [RAGContextItem]) async -> RAGAnswer {
        isProcessing = true
        defer { isProcessing = false }
        lastError = nil

        let startTime = Date()

        // Context must be provided by caller
        if contextItems.isEmpty {
            return RAGAnswer(
                question: question,
                answer: "I couldn't find any relevant content in your clipboard history.",
                sources: 0,
                model: "local",
                timeMs: Date().timeIntervalSince(startTime) * 1000
            )
        }

        // Generate answer using local LLM
        guard let localAI = localAI else {
            lastError = "Local AI not available"
            return RAGAnswer(
                question: question,
                answer: "AI service unavailable.",
                sources: contextItems.count,
                model: "none",
                timeMs: Date().timeIntervalSince(startTime) * 1000
            )
        }

        let answer = await localAI.generateAnswer(
            question: question,
            clipboardContext: contextItems,
            appName: nil
        ) ?? "I couldn't generate an answer."

        let timeMs = Date().timeIntervalSince(startTime) * 1000

        return RAGAnswer(
            question: question,
            answer: answer,
            sources: contextItems.count,
            model: "Qwen2.5-1.5B",
            timeMs: timeMs
        )
    }

    /// Simple text chunking for long documents.
    func chunkText(_ text: String, maxChunkSize: Int = 500, overlap: Int = 50) -> [String] {
        guard text.count > maxChunkSize else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[start..<end])
            chunks.append(chunk)

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
