import Foundation
import os

/// OpenAI provider using the Chat Completions API.
@MainActor
class OpenAIProvider: ObservableObject, AIProvider {
    let id = "openai"
    let displayName = "OpenAI (GPT)"
    let providerType: ProviderType = .cloud
    let capabilities: Set<AICapability> = [.textGeneration, .streaming, .vision, .tagging]

    @Published var isProcessing = false
    @Published var lastError: String?

    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o-mini"
    private let keychainKey = "OpenAI_API_Key"

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
            Logger.ai.warning("OpenAI API key not configured")
            return nil
        }

        isProcessing = true
        defer { isProcessing = false }

        let contextText = clipboardContext.prefix(10).enumerated().map { index, item in
            "[\(index + 1)] \(item.content.prefix(500))"
        }.joined(separator: "\n\n")

        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are a helpful clipboard assistant. Answer questions using ONLY the clipboard context provided. Be concise and direct. Return the direct answer without preamble."],
            ["role": "user", "content": "Clipboard context:\n\(contextText)\n\nQuestion: \(question)"]
        ]

        return await callOpenAI(messages: messages)
    }

    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return [] }

        isProcessing = true
        defer { isProcessing = false }

        let messages: [[String: Any]] = [
            ["role": "system", "content": "Generate 3-5 semantic tags for the given content. Return ONLY a comma-separated list of lowercase tags, nothing else."],
            ["role": "user", "content": "Content from \(appName ?? "Unknown"): \(content.prefix(500))"]
        ]

        guard let response = await callOpenAI(messages: messages) else { return [] }

        return response
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.count < 30 }
    }

    func analyzeImage(imageData: Data) async -> String? {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return nil }

        isProcessing = true
        defer { isProcessing = false }

        let base64Image = imageData.base64EncodedString()
        let messages: [[String: Any]] = [
            ["role": "user", "content": [
                ["type": "text", "text": "Give a quick summary of this image."],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64Image)"]]
            ] as [Any]]
        ]

        return await callOpenAI(messages: messages)
    }

    // MARK: - API Call

    private func callOpenAI(messages: [[String: Any]], maxTokens: Int = 1024) async -> String? {
        guard let apiKey = apiKey else { return nil }

        guard let url = URL(string: baseURL) else {
            lastError = "Invalid URL"
            return nil
        }

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = "OpenAI API error (\(statusCode))"
                Logger.network.error("OpenAI API error: \(statusCode, privacy: .public)")
                return nil
            }

            // Parse response: { "choices": [{"message": {"content": "..."}}] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                lastError = "Failed to parse OpenAI response"
                return nil
            }

            return content.trimmingCharacters(in: .whitespacesAndNewlines)

        } catch {
            lastError = error.localizedDescription
            Logger.network.error("OpenAI request error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
