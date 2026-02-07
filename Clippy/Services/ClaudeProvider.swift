import Foundation
import os

/// Claude AI provider using the Anthropic Messages API.
@MainActor
class ClaudeProvider: ObservableObject, AIProvider {
    let id = "claude"
    let displayName = "Claude (Anthropic)"
    let providerType: ProviderType = .cloud
    let capabilities: Set<AICapability> = [.textGeneration, .streaming, .tagging]

    @Published var isProcessing = false
    @Published var lastError: String?

    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-5-20250929"
    private let keychainKey = "Claude_API_Key"

    var isAvailable: Bool {
        KeychainHelper.load(key: keychainKey) != nil
    }

    private var apiKey: String? {
        KeychainHelper.load(key: keychainKey)
    }

    // MARK: - AIServiceProtocol

    func generateAnswer(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) async -> String? {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            Logger.ai.warning("Claude API key not configured")
            return nil
        }

        isProcessing = true
        defer { isProcessing = false }

        let contextText = clipboardContext.prefix(10).enumerated().map { index, item in
            "[\(index + 1)] \(item.content.prefix(500))"
        }.joined(separator: "\n\n")

        let systemPrompt = "You are a helpful clipboard assistant. Answer questions using ONLY the clipboard context provided. Be concise and direct. Return the direct answer without preamble."
        let userMessage = """
        Clipboard context:
        \(contextText)

        Question: \(question)
        """

        return await callClaude(systemPrompt: systemPrompt, userMessage: userMessage)
    }

    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return [] }

        isProcessing = true
        defer { isProcessing = false }

        let systemPrompt = "Generate 3-5 semantic tags for the given content. Return ONLY a comma-separated list of lowercase tags, nothing else."
        let userMessage = "Content from \(appName ?? "Unknown"): \(content.prefix(500))"

        guard let response = await callClaude(systemPrompt: systemPrompt, userMessage: userMessage) else {
            return []
        }

        return response
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.count < 30 }
    }

    func analyzeImage(imageData: Data) async -> String? {
        // Vision not yet implemented for Claude provider
        return nil
    }

    // MARK: - API Call

    private func callClaude(systemPrompt: String, userMessage: String) async -> String? {
        guard let apiKey = apiKey else { return nil }

        guard let url = URL(string: baseURL) else {
            lastError = "Invalid URL"
            return nil
        }

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = "Claude API error (\(statusCode))"
                Logger.network.error("Claude API error: \(statusCode, privacy: .public)")
                return nil
            }

            // Parse Anthropic response: { "content": [{"type": "text", "text": "..."}] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contentArray = json["content"] as? [[String: Any]],
                  let firstBlock = contentArray.first,
                  let text = firstBlock["text"] as? String else {
                lastError = "Failed to parse Claude response"
                return nil
            }

            return text.trimmingCharacters(in: .whitespacesAndNewlines)

        } catch {
            lastError = error.localizedDescription
            Logger.network.error("Claude request error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
