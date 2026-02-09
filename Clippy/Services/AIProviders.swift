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


/// Ollama provider connecting to a local Ollama instance.
@MainActor
class OllamaProvider: ObservableObject, AIProvider {
    let id = "ollama"
    let displayName = "Ollama (Local)"
    let providerType: ProviderType = .local
    let capabilities: Set<AICapability> = [.textGeneration, .streaming, .tagging]

    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = "llama3.2"

    private let baseURL = "http://localhost:11434"

    var isAvailable: Bool {
        !availableModels.isEmpty
    }

    /// Probe Ollama server and populate available models.
    func detectAvailability() async {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                availableModels = []
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                availableModels = models.compactMap { $0["name"] as? String }
                Logger.ai.info("Ollama detected with \(self.availableModels.count, privacy: .public) models")
                if !availableModels.contains(selectedModel), let first = availableModels.first {
                    selectedModel = first
                }
            }
        } catch {
            availableModels = []
            Logger.ai.debug("Ollama not available: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - AIServiceProtocol

    func generateAnswer(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) async -> String? {
        isProcessing = true
        defer { isProcessing = false }

        let contextText = clipboardContext.prefix(10).enumerated().map { index, item in
            "[\(index + 1)] \(item.content.prefix(500))"
        }.joined(separator: "\n\n")

        let prompt = """
        You are a helpful clipboard assistant. Answer using ONLY the clipboard context.

        Clipboard context:
        \(contextText)

        Question: \(question)

        Be concise and direct. Return the direct answer without preamble.
        """

        return await callOllama(prompt: prompt)
    }

    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        isProcessing = true
        defer { isProcessing = false }

        let prompt = "Generate 3-5 semantic tags for this content. Return ONLY a comma-separated list of lowercase tags.\n\nContent from \(appName ?? "Unknown"): \(content.prefix(500))"

        guard let response = await callOllama(prompt: prompt) else { return [] }

        return response
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.count < 30 }
    }

    func analyzeImage(imageData: Data) async -> String? {
        return nil
    }

    // MARK: - API Call

    private func callOllama(prompt: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            lastError = "Invalid URL"
            return nil
        }

        let requestBody: [String: Any] = [
            "model": selectedModel,
            "prompt": prompt,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = "Ollama error (\(statusCode))"
                Logger.network.error("Ollama API error: \(statusCode, privacy: .public)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                lastError = "Failed to parse Ollama response"
                return nil
            }

            return responseText.trimmingCharacters(in: .whitespacesAndNewlines)

        } catch {
            lastError = error.localizedDescription
            Logger.network.error("Ollama request error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Gemini Provider

struct GeminiAPIResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable {
            struct Part: Codable {
                let text: String?
            }
            let parts: [Part]?
            let role: String?
        }
        let content: Content?
        let finishReason: String?
    }
    let candidates: [Candidate]?
}

@MainActor
class GeminiProvider: ObservableObject, AIProvider {
    let id = "gemini"
    let displayName = "Gemini (Google)"
    let providerType: ProviderType = .cloud
    let capabilities: Set<AICapability> = [.textGeneration, .vision, .tagging]

    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var lastErrorMessage: String?

    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    private let modelName = "gemini-2.5-flash"
    private let keychainKey = "Gemini_API_Key"
    private let rateLimiter = TokenBucketRateLimiter(maxTokens: 10, refillRate: 2)
    private var lastTagRequestTime: Date?
    private let tagDebounceInterval: TimeInterval = 2.0

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
        let legacyContext = clipboardContext.map { (content: $0.content, tags: $0.tags) }
        let (answer, _) = await generateAnswerWithImageDetection(
            question: question,
            clipboardContext: legacyContext,
            appName: appName
        )
        return answer
    }

    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        let now = Date()
        if let lastTime = lastTagRequestTime, now.timeIntervalSince(lastTime) < tagDebounceInterval {
            return []
        }
        lastTagRequestTime = now

        isProcessing = true
        defer { isProcessing = false }

        let prompt = buildTaggingPrompt(content: content, appName: appName, context: context)
        guard let tags = await callGemini(prompt: prompt) else { return [] }
        return tags
    }

    func analyzeImage(imageData: Data) async -> String? {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return nil }

        let base64Image = imageData.base64EncodedString()
        guard let url = URL(string: "\(baseURL)/\(modelName):generateContent") else { return nil }

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "give quick summary of it."],
                        [
                            "inline_data": [
                                "mime_type": "image/png",
                                "data": base64Image
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": ["maxOutputTokens": 8192]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }

            let apiResponse = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)
            return apiResponse.candidates?.first?.content?.parts?.first?.text
        } catch {
            return nil
        }
    }

    // MARK: - Internal Logic

    func generateAnswerWithImageDetection(
        question: String,
        clipboardContext: [(content: String, tags: [String])],
        appName: String?
    ) async -> (answer: String?, imageIndex: Int?) {
        isProcessing = true
        defer { isProcessing = false }
        
        let prompt = buildAnswerPrompt(question: question, clipboardContext: clipboardContext, appName: appName)
        return await callGeminiForAnswerWithImage(prompt: prompt) ?? (nil, nil)
    }

    private func buildAnswerPrompt(question: String, clipboardContext: [(content: String, tags: [String])], appName: String?) -> String {
        let contextText: String
        if clipboardContext.isEmpty {
            contextText = "No clipboard context available."
        } else {
            contextText = clipboardContext.enumerated().map { index, item in
                let tagsText = item.tags.isEmpty ? "" : " [Tags: \(item.tags.joined(separator: ", "))]"
                return "[\(index + 1)]\(tagsText)\n\(item.content)"
            }.joined(separator: "\n\n---\n\n")
        }
        
        let prompt = """
        You are a Clippy assistant. Answer the user's question based on their clipboard history.
        User Question: \(question)
        Clipboard Context:
        \(contextText)
        App: \(appName ?? "Unknown")

        CRITICAL RULES:
        1. If user asks to paste/show/insert an image, return the item number in paste_image (1-based).
        2. For text questions, answer directly in A with no preamble.
        3. If the question is not about clipboard content, return an empty string in A.
        4. OUTPUT MUST BE VALID JSON ONLY (no markdown, no extra text).

        OUTPUT FORMAT:
        { "A": "direct answer", "paste_image": 0 }
        """
        return prompt
    }

    private func buildTaggingPrompt(content: String, appName: String?, context: String?) -> String {
        return """
        App: \(appName ?? "Unknown")
        Content: \(content.prefix(500))
        Generate 3-7 semantic tags. Return ONLY JSON (no markdown, no extra text):
        { "tags": ["tag1", "tag2"] }
        """
    }

    private func callGeminiAPI(body: [String: Any], label: String) async -> String? {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            lastErrorMessage = "API key not configured."
            return nil
        }
        guard let url = URL(string: "\(baseURL)/\(modelName):generateContent") else { return nil }

        let maxRetries = 3
        let backoffDelays: [Double] = [1, 2, 4]

        for attempt in 0...maxRetries {
            await rateLimiter.acquire()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = "Invalid response"
                    lastErrorMessage = "Network error - invalid response"
                    return nil
                }

                if httpResponse.statusCode == 429 && attempt < maxRetries {
                    lastErrorMessage = "Rate limited. Retrying..."
                    try? await Task.sleep(for: .seconds(backoffDelays[attempt]))
                    continue
                }

                guard httpResponse.statusCode == 200 else {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    lastError = "API Error (\(httpResponse.statusCode)): \(errorMessage)"
                    switch httpResponse.statusCode {
                    case 400: lastErrorMessage = "Bad request - check your query"
                    case 401, 403: lastErrorMessage = "Invalid API key. Check Settings."
                    case 429: lastErrorMessage = "Rate limited. Try again later."
                    case 500...599: lastErrorMessage = "Gemini server error. Try again."
                    default: lastErrorMessage = "API error (\(httpResponse.statusCode))"
                    }
                    return nil
                }

                // Clear error on success
                lastErrorMessage = nil
                lastError = nil

                let apiResponse = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)
                let text = apiResponse.candidates?.first?.content?.parts?.first?.text ?? ""
                return cleanMarkdownJSON(text)

            } catch let error as URLError {
                lastError = error.localizedDescription
                switch error.code {
                case .notConnectedToInternet: lastErrorMessage = "No internet connection"
                case .timedOut: lastErrorMessage = "Request timed out. Try again."
                default: lastErrorMessage = "Network error. Check connection."
                }
                return nil
            } catch {
                lastError = error.localizedDescription
                lastErrorMessage = "Something went wrong. Try again."
                return nil
            }
        }
        return nil
    }

    private func callGeminiForAnswerWithImage(prompt: String) async -> (String?, Int?)? {
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["response_mime_type": "application/json", "maxOutputTokens": 8192]
        ]
        guard let text = await callGeminiAPI(body: body, label: "Answer") else { return nil }

        if let jsonData = text.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let answer = (jsonObject["A"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pasteImage = jsonObject["paste_image"] as? Int
            return (answer, pasteImage)
        }
        return (text, nil)
    }

    private func callGemini(prompt: String) async -> [String]? {
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["response_mime_type": "application/json", "maxOutputTokens": 8192]
        ]
        guard let text = await callGeminiAPI(body: body, label: "Tags") else { return nil }

        if let jsonData = text.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let tagsHelper = jsonObject["tags"] as? [String] {
            return tagsHelper
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func cleanMarkdownJSON(_ text: String) -> String {
        var cleaned = text
        if cleaned.contains("```json") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        } else if cleaned.contains("```") {
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
