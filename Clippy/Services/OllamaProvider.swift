import Foundation
import os

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
