import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var container: AppDependencyContainer
    @Binding var apiKey: String
    @Binding var elevenLabsKey: String
    @Binding var selectedService: AIServiceType

    @State private var tempGeminiKey: String = ""
    @State private var tempElevenLabsKey: String = ""
    @State private var tempClaudeKey: String = ""
    @State private var tempOpenAIKey: String = ""
    @State private var showExportSuccess: Bool = false
    @State private var showImportResult: String?
    @State private var showDiagnosticsCopied: Bool = false
    @State private var showClearConfirmation: Bool = false
    @State private var showReindexSuccess: Bool = false
    @State private var selectedTab: SettingsTab = .general
    @State private var geminiKeyStatus: KeyValidationStatus = .untested
    @State private var claudeKeyStatus: KeyValidationStatus = .untested
    @State private var openaiKeyStatus: KeyValidationStatus = .untested

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case ai = "AI"
        case privacy = "Privacy"
        case about = "About"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .general: return "gearshape"
            case .ai: return "brain"
            case .privacy: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        VStack(spacing: 4) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 16))
                            Text(tab.rawValue)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .general:
                        generalTab
                    case .ai:
                        aiTab
                    case .privacy:
                        privacyTab
                    case .about:
                        aboutTab
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    apiKey = tempGeminiKey
                    elevenLabsKey = tempElevenLabsKey
                    // Save Claude and OpenAI keys to Keychain
                    if !tempClaudeKey.isEmpty {
                        KeychainHelper.save(key: "Claude_API_Key", value: tempClaudeKey)
                    }
                    if !tempOpenAIKey.isEmpty {
                        KeychainHelper.save(key: "OpenAI_API_Key", value: tempOpenAIKey)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 520, height: 580)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("History") {
                HStack {
                    Text("Max clipboard items")
                        .font(.system(size: 13))
                    Spacer()
                    Text("Unlimited")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            settingsSection("Data Management") {
                HStack(spacing: 12) {
                    Button("Export Data") { exportData() }
                    Button("Import Data") { importData() }
                    Button("Re-index Search") { reindexSearch() }
                }

                if showExportSuccess {
                    Text("Data exported successfully.")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                if let importResult = showImportResult {
                    Text(importResult)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if showReindexSuccess {
                    Text("Search index rebuilt successfully.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            settingsSection("Danger Zone") {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Clear All Clipboard History", systemImage: "trash")
                }
                .confirmationDialog(
                    "Clear All Clipboard History?",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear All", role: .destructive) { clearAllHistory() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete all clipboard items. This action cannot be undone.")
                }

                Text("Permanently removes all items from your clipboard history.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - AI Tab

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("AI Service") {
                Picker("Active Provider", selection: $selectedService) {
                    ForEach(AIServiceType.allCases, id: \.self) { service in
                        Text(service.description).tag(service)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            settingsSection("Gemini API Key") {
                SecureField("Enter Gemini API key...", text: $tempGeminiKey)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { tempGeminiKey = apiKey }

                HStack {
                    Button(action: { testGeminiKey() }) {
                        HStack(spacing: 4) {
                            if geminiKeyStatus == .testing {
                                ProgressView().scaleEffect(0.6)
                            }
                            Text(geminiKeyStatus == .valid ? "Valid" : geminiKeyStatus == .invalid ? "Invalid" : "Test")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(geminiKeyStatus == .valid ? .green : geminiKeyStatus == .invalid ? .red : nil)
                    .disabled(tempGeminiKey.isEmpty || geminiKeyStatus == .testing)

                    Spacer()
                }

                Text("Required for Gemini services. Keys are stored in Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            settingsSection("Claude API Key") {
                SecureField("Enter Claude API key...", text: $tempClaudeKey)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { tempClaudeKey = KeychainHelper.load(key: "Claude_API_Key") ?? "" }

                HStack {
                    Button(action: { testClaudeKey() }) {
                        HStack(spacing: 4) {
                            if claudeKeyStatus == .testing {
                                ProgressView().scaleEffect(0.6)
                            }
                            Text(claudeKeyStatus == .valid ? "Valid" : claudeKeyStatus == .invalid ? "Invalid" : "Test")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(claudeKeyStatus == .valid ? .green : claudeKeyStatus == .invalid ? .red : nil)
                    .disabled(tempClaudeKey.isEmpty || claudeKeyStatus == .testing)

                    Spacer()
                }

                Text("Required for Claude AI service. Keys are stored in Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            settingsSection("OpenAI API Key") {
                SecureField("Enter OpenAI API key...", text: $tempOpenAIKey)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { tempOpenAIKey = KeychainHelper.load(key: "OpenAI_API_Key") ?? "" }

                HStack {
                    Button(action: { testOpenAIKey() }) {
                        HStack(spacing: 4) {
                            if openaiKeyStatus == .testing {
                                ProgressView().scaleEffect(0.6)
                            }
                            Text(openaiKeyStatus == .valid ? "Valid" : openaiKeyStatus == .invalid ? "Invalid" : "Test")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(openaiKeyStatus == .valid ? .green : openaiKeyStatus == .invalid ? .red : nil)
                    .disabled(tempOpenAIKey.isEmpty || openaiKeyStatus == .testing)

                    Spacer()
                }

                Text("Required for OpenAI (GPT) service. Keys are stored in Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            settingsSection("ElevenLabs API Key") {
                SecureField("Enter ElevenLabs API key...", text: $tempElevenLabsKey)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { tempElevenLabsKey = elevenLabsKey }

                Text("Required for voice input (Option+Space). Keys are stored in Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            settingsSection("Usage Today") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("API Calls")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(container.usageTracker.todayCalls)")
                            .font(.title3)
                            .fontWeight(.medium)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Est. Cost")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "$%.4f", container.usageTracker.todayCost))
                            .font(.title3)
                            .fontWeight(.medium)
                    }
                }

                if !container.usageTracker.perProviderToday.isEmpty {
                    ForEach(Array(container.usageTracker.perProviderToday.keys.sorted()), id: \.self) { provider in
                        if let stats = container.usageTracker.perProviderToday[provider] {
                            HStack {
                                Text(provider.capitalized)
                                    .font(.caption)
                                Spacer()
                                Text("\(stats.calls) calls")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "$%.4f", stats.cost))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Privacy Tab

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("Sensitive Content") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-detect sensitive content")
                            .font(.system(size: 13))
                        Text("API keys, passwords, credit cards are automatically masked")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("Active")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            settingsSection("Permissions") {
                HStack {
                    Image(systemName: "hand.raised.fill")
                        .foregroundColor(.blue)
                    Text("Accessibility")
                    Spacer()
                    Image(systemName: AXIsProcessTrusted() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(AXIsProcessTrusted() ? .green : .red)
                }
                .font(.system(size: 13))

                if !AXIsProcessTrusted() {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("Clippy") {
                HStack {
                    Text("Version")
                        .font(.system(size: 13))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Build")
                        .font(.system(size: 13))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            settingsSection("Diagnostics") {
                Button(showDiagnosticsCopied ? "Copied" : "Copy Diagnostics") {
                    copyDiagnostics()
                }
                .foregroundColor(showDiagnosticsCopied ? .green : nil)

                Text("Copies system info to clipboard (no user data included).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Section Helper

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Data Actions

    private func exportData() {
        let descriptor = FetchDescriptor<Item>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        guard let items = try? modelContext.fetch(descriptor) else { return }
        guard let data = DataExporter.exportItems(items) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clippy-backup.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
            showExportSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showExportSuccess = false }
        }
    }

    private func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard let data = try? Data(contentsOf: url) else {
                showImportResult = "Failed to read file."
                return
            }
            let count = DataExporter.importItems(from: data, into: modelContext)
            showImportResult = "Imported \(count) items."
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showImportResult = nil }
        }
    }

    private func copyDiagnostics() {
        let descriptor = FetchDescriptor<Item>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        DiagnosticExporter.copyDiagnosticsToClipboard(
            itemCount: count,
            aiService: selectedService,
            lastError: nil
        )
        showDiagnosticsCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDiagnosticsCopied = false }
    }

    // MARK: - Maintenance Actions

    private func reindexSearch() {
        Task {
            let descriptor = FetchDescriptor<Item>()
            guard let items = try? modelContext.fetch(descriptor) else { return }

            let documents = items.compactMap { item -> (UUID, String)? in
                guard let vid = item.vectorId else { return nil }
                let text = (item.title != nil && !item.title!.isEmpty) ? "\(item.title!)\n\n\(item.content)" : item.content
                return (vid, text)
            }

            if !documents.isEmpty {
                await container.vectorSearch.addDocuments(items: documents)
            }

            await MainActor.run {
                showReindexSuccess = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showReindexSuccess = false }
            }
        }
    }

    private func clearAllHistory() {
        guard let repository = container.repository else { return }

        Task {
            let descriptor = FetchDescriptor<Item>()
            guard let items = try? modelContext.fetch(descriptor) else { return }

            for item in items {
                try? await repository.deleteItem(item)
            }
        }
    }

    // MARK: - API Key Validation

    private enum KeyValidationStatus {
        case untested, testing, valid, invalid
    }

    private func testGeminiKey() {
        geminiKeyStatus = .testing
        Task {
            let valid = await testAPIEndpoint(
                url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(tempGeminiKey)")!
            )
            geminiKeyStatus = valid ? .valid : .invalid
        }
    }

    private func testClaudeKey() {
        claudeKeyStatus = .testing
        Task {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(tempClaudeKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": "claude-sonnet-4-5-20250929",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ])
            let valid = await testAPIRequest(request: request)
            claudeKeyStatus = valid ? .valid : .invalid
        }
    }

    private func testOpenAIKey() {
        openaiKeyStatus = .testing
        Task {
            let valid = await testAPIEndpoint(
                url: URL(string: "https://api.openai.com/v1/models")!,
                headers: ["Authorization": "Bearer \(tempOpenAIKey)"]
            )
            openaiKeyStatus = valid ? .valid : .invalid
        }
    }

    private func testAPIEndpoint(url: URL, headers: [String: String] = [:]) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func testAPIRequest(request: URLRequest) async -> Bool {
        var req = request
        req.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200
        } catch {
            return false
        }
    }
}
