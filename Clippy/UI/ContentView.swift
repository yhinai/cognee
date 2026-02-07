import SwiftUI
import SwiftData
import os

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var container: AppDependencyContainer
    
    // Derived properties for cleaner access (optional, but helps avoid massive find/replace)
    private var clipboardMonitor: ClipboardMonitor { container.clipboardMonitor }
    private var vectorSearch: VectorSearchService { container.vectorSearch }
    private var hotkeyManager: HotkeyManager { container.hotkeyManager }
    private var visionParser: VisionScreenParser { container.visionParser }
    private var textCaptureService: TextCaptureService { container.textCaptureService }
    private var clippyController: ClippyWindowController { container.clippyController }
    private var localAIService: LocalAIService { container.localAIService }
    private var geminiService: GeminiService { container.geminiService }
    private var audioRecorder: AudioRecorder { container.audioRecorder }

    // Constants/State
    @State private var elevenLabsService: ElevenLabsService?
    @State private var isRecordingVoice = false
    
    // Navigation State
    @State private var selectedCategory: NavigationCategory? = .allItems
    @State private var selectedItems: Set<PersistentIdentifier> = []
    @State private var searchText: String = ""
    @State private var showSettings: Bool = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showOnboarding: Bool = false
    @State private var showDatabaseResetAlert: Bool = false

    // AI Processing State
    @State private var thinkingStartTime: Date? // Track when thinking state started
    
    // Items Query for context (we still need this for AI context even if list has its own query)
    @Query(sort: \Item.timestamp, order: .reverse) private var allItems: [Item]

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selectedCategory,
                selectedAIService: $container.selectedAIServiceType,
                clippyController: clippyController,
                showSettings: $showSettings,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } content: {
            ClipboardListView(
                selectedItems: $selectedItems,
                category: selectedCategory ?? .allItems,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 520)
        } detail: {
            // Show first selected item in detail view
            if let firstSelectedId = selectedItems.first,
               let item = allItems.first(where: { $0.id == firstSelectedId }) {
                ClipboardDetailView(item: item)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))

                    Text("\(allItems.count) items in your clipboard")
                        .font(.title3.weight(.medium))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        KeyboardShortcutHint(keys: "⇧⌘V", description: "Search overlay")
                        KeyboardShortcutHint(keys: "⌥X", description: "Ask AI")
                        KeyboardShortcutHint(keys: "⌥V", description: "OCR capture")
                        KeyboardShortcutHint(keys: "⌥␣", description: "Voice input")
                    }
                    .padding(.top, 4)
                }
                .padding(32)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                apiKey: Binding(
                    get: { getStoredAPIKey() },
                    set: { saveAPIKey($0) }
                ),
                elevenLabsKey: Binding(
                    get: { KeychainHelper.load(key: "ElevenLabs_API_Key") ?? "" },
                    set: {
                        KeychainHelper.save(key: "ElevenLabs_API_Key", value: $0)
                        if !$0.isEmpty {
                            elevenLabsService = ElevenLabsService(apiKey: $0)
                        } else {
                            elevenLabsService = nil
                        }
                    }
                ),
                selectedService: $container.selectedAIServiceType
            )
            .environmentObject(container)
        }
        .onChange(of: clipboardMonitor.hasAccessibilityPermission) { _, granted in
            if granted && !hotkeyManager.isListening {
                Logger.ui.info("Permissions granted, restarting HotkeyManager")
                startHotkeys()
            }
        }
        .onAppear {
            setupServices()
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            if UserDefaults.standard.bool(forKey: "didResetDatabase") {
                showDatabaseResetAlert = true
                UserDefaults.standard.removeObject(forKey: "didResetDatabase")
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(selectedAIService: $container.selectedAIServiceType) {
                hasCompletedOnboarding = true
                showOnboarding = false
            }
        }
        .alert("Database Reset", isPresented: $showDatabaseResetAlert) {
            Button("OK") { }
        } message: {
            Text("Your clipboard history was reset due to a database update. This is a one-time occurrence and your new items will be saved normally.")
        }
    }
    
    // MARK: - Setup & Services
    
    private func setupServices() {
        // Load stored API key
        let storedKey = getStoredAPIKey()
        if !storedKey.isEmpty {
            geminiService.updateApiKey(storedKey)
        }
        
        // Initialize ElevenLabs Service
        let elevenLabsKey = getStoredElevenLabsKey()
        if !elevenLabsKey.isEmpty {
            elevenLabsService = ElevenLabsService(apiKey: elevenLabsKey)
        }
        
        Task {
            // Initialize Vector DB
            await vectorSearch.initialize()
        }
        
        // Start hotkeys on main thread (required for CGEvent tap)
        startHotkeys()
    }
    
    private func startHotkeys() {
        hotkeyManager.startListening(
            onVisionTrigger: { handleVisionHotkeyTrigger() },
            onTextCaptureTrigger: { handleTextCaptureTrigger() },
            onVoiceCaptureTrigger: { toggleVoiceRecording() },
            onUndoTrigger: { textCaptureService.undoLastReplacement() },
            isUndoAvailable: { [weak textCaptureService] in textCaptureService?.canUndo ?? false },
            onSearchOverlayTrigger: { handleSearchOverlayTrigger() }
        )
    }

    private func handleSearchOverlayTrigger() {
        Logger.ui.info("Search overlay hotkey triggered (Cmd+Shift+V)")
        container.searchOverlayController.toggle(
            modelContainer: modelContext.container,
            container: container
        )
    }
    
    // MARK: - Input Mode Management

    @State private var activeInputMode: InputMode = .none
    
    private func resetInputState() {
        // Cancel text capture
        if textCaptureService.isCapturing {
            textCaptureService.stopCapturing()
        }
        
        // Cancel voice recording
        if isRecordingVoice {
            isRecordingVoice = false
            _ = audioRecorder.stopRecording()
        }
        
        // Reset UI state
        if activeInputMode != .none {
            // Only hide if we were actually doing something
            clippyController.hide()
        }
        
        activeInputMode = .none
        thinkingStartTime = nil
    }
    
    private func handleVisionHotkeyTrigger() {
        Logger.ui.info("Vision hotkey triggered (Option+V)")

        // Vision is a one-shot action, but we should still reset other modes
        resetInputState()
        activeInputMode = .visionCapture

        clippyController.setState(.thinking, message: "Capturing screen... 📸")

        Task {
            let result = await visionParser.parseCurrentScreen()

            await MainActor.run {
                switch result {
                case .success(let parsedContent):
                    Logger.ui.info("Vision parsing successful - extracted \(parsedContent.fullText.count, privacy: .public) characters")
                    if !parsedContent.fullText.isEmpty {
                        // If we have image data and Local AI is selected, generate a description
                        if self.container.selectedAIServiceType == .local, let imageData = parsedContent.imageData {
                            self.clippyController.setState(.thinking, message: "Analyzing image... 🧠")

                            Task {
                                let base64Image = imageData.base64EncodedString()
                                if let description = await self.localAIService.generateVisionDescription(base64Image: base64Image) {
                                    await MainActor.run {
                                        self.saveVisionContent(description, originalText: parsedContent.fullText)
                                        self.clippyController.setState(.done, message: "Image analyzed! ✨")
                                    }
                                } else {
                                    await MainActor.run {
                                        self.saveVisionContent(parsedContent.fullText)
                                        self.clippyController.setState(.done, message: "Saved text (Vision failed) ⚠️")
                                    }
                                }
                            }
                        } else {
                            self.saveVisionContent(parsedContent.fullText)
                            self.clippyController.setState(.done, message: "Saved \(parsedContent.fullText.count) chars! ✅")
                        }
                    } else {
                        self.clippyController.setState(.error, message: "No text found 👀")
                    }
                case .failure(let error):
                    Logger.ui.error("Vision parsing failed: \(error.localizedDescription, privacy: .public)")

                    // Check if it's a permission error
                    if case VisionParserError.screenCaptureFailed = error {
                        self.clippyController.setState(.error, message: "Need Screen Recording permission 🔐")
                        // Open System Settings
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        self.clippyController.setState(.error, message: "Vision failed: \(error.localizedDescription)")
                    }
                }

                // Reset mode after short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.activeInputMode == .visionCapture {
                        self.activeInputMode = .none
                    }
                }
            }
        }
    }
    
    private func saveVisionContent(_ text: String, originalText: String? = nil) {
        guard let repository = container.repository else { return }
        
        // Deduplication check could be done here, but simplified for brevity
        let contentToSave = originalText != nil ? "Image Description:\n\(text)\n\nExtracted Text:\n\(originalText!)" : text
        
        Task {
            do {
                _ = try await repository.saveItem(
                    content: contentToSave,
                    appName: clipboardMonitor.currentAppName,
                    contentType: "vision-parsed",
                    timestamp: Date(),
                    tags: [],
                    vectorId: nil,
                    imagePath: nil,
                    title: nil,
                    isSensitive: false,
                    expiresAt: nil
                )
                Logger.ui.info("Vision content saved via Repository")
            } catch {
                Logger.ui.error("Failed to save vision content: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func handleTextCaptureTrigger() {
        Logger.ui.info("Text capture hotkey triggered (Option+X)")
        
        if activeInputMode == .textCapture {
            // Second press: Stop capturing and start thinking
            if textCaptureService.isCapturing {
                clippyController.setState(.thinking)
                thinkingStartTime = Date() // Record when thinking started
                textCaptureService.stopCapturing()
                // Processing happens in onComplete callback
            } else {
                // Should not happen if state is consistent, but safe fallback
                resetInputState()
            }
        } else {
            // Switch to text capture mode
            resetInputState()
            activeInputMode = .textCapture
            
            clippyController.setState(.idle)
            textCaptureService.startCapturing(
                onTypingDetected: {
                    // Switch to writing state when user starts typing
                    self.clippyController.setState(.writing)
                },
                onComplete: { capturedText in
                    self.processCapturedText(capturedText)
                }
            )
        }
    }
    
    private func processCapturedText(_ capturedText: String) {
        Logger.ui.info("Processing captured text")

        // Ensure thinking state is set and time is recorded
        if thinkingStartTime == nil {
            thinkingStartTime = Date()
        }
        clippyController.setState(.thinking)

        Task {
            let result = await container.queryOrchestrator.processQuery(
                query: capturedText,
                allItems: allItems,
                aiServiceType: container.selectedAIServiceType,
                appName: clipboardMonitor.currentAppName,
                onStreamingToken: { fullAnswer in
                    let preview = fullAnswer.suffix(50).replacingOccurrences(of: "\n", with: " ")
                    self.clippyController.setState(.writing, message: "...\(preview)")
                }
            )

            await MainActor.run {
                handleAIResponse(
                    answer: result.answer,
                    imageIndex: result.imageIndex,
                    contextItems: result.contextItems,
                    errorMessage: result.errorMessage
                )
            }
        }
    }
    
    private func handleAIResponse(answer: String?, imageIndex: Int?, contextItems: [Item], errorMessage: String? = nil) {
        // Calculate how long we've been in thinking state
        let elapsed = Date().timeIntervalSince(thinkingStartTime ?? Date())
        let remainingDelay = max(0, 0.5 - elapsed) // Minimum 0.5 seconds of thinking
        
        Logger.ui.info("AI response received. Elapsed: \(elapsed, privacy: .public)s, Remaining delay: \(remainingDelay, privacy: .public)s")
        
        // Delay transition to done state if needed to ensure minimum 3s thinking
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay) {
            self.thinkingStartTime = nil // Reset thinking timer
            
            // Check if there was an error
            if let errorMessage = errorMessage {
                self.clippyController.setState(.error, message: "❌ \(errorMessage)")
                // Auto-hide after showing error
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.clippyController.hide()
                }
                return
            }
            
            // Transition to done state
            self.clippyController.setState(.done)
            
            if let imageIndex = imageIndex, imageIndex > 0, imageIndex <= contextItems.count {
                let item = contextItems[imageIndex - 1]
                if item.contentType == "image", let imagePath = item.imagePath {
                    self.container.clipboardMonitor.skipNextClipboardChange = true
                    ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
                    
                    // Delete original item logic via Repository
                    if let repository = self.container.repository {
                        Task {
                            try? await repository.deleteItem(item)
                        }
                    }
                    
                    self.textCaptureService.replaceCapturedTextWithAnswer("")
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.simulatePaste()
                        self.clippyController.setState(.done, message: "Image pasted! 🖼️")
                    }
                } else {
                    self.clippyController.setState(.idle, message: "That's not an image 🤔")
                }
            } else if let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
                // Handle based on input mode
                if self.activeInputMode == .textCapture {
                    // For text capture: replace captured text with answer
                    self.textCaptureService.replaceCapturedTextWithAnswer(answer)
                    self.clippyController.setState(.done, message: "Answer ready! 🎉")
                } else if self.activeInputMode == .voiceCapture {
                    // For voice: insert answer at current cursor position
                    self.textCaptureService.insertTextAtCursor(answer)
                    self.clippyController.setState(.done, message: "Answer ready! 🎉")
                } else {
                    // Fallback: insert at cursor
                    self.textCaptureService.insertTextAtCursor(answer)
                    self.clippyController.setState(.done, message: "Answer ready! 🎉")
                }
            } else {
                self.clippyController.setState(.idle, message: "Question not relevant to clipboard 📋")
            }
            
            // Reset input mode after processing
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                // Only reset if still in the same mode (user hasn't started something else)
                if self.activeInputMode == .textCapture || self.activeInputMode == .voiceCapture {
                    self.activeInputMode = .none
                }
            }
        }
    }
    
    private func toggleVoiceRecording() {
        Logger.ui.info("Voice capture hotkey triggered (Option+Space)")
        
        if activeInputMode == .voiceCapture {
            // Second press: Stop Recording & Process
            if isRecordingVoice {
                isRecordingVoice = false
                clippyController.setState(.thinking) // Dog looks like it's thinking
                
                guard let url = audioRecorder.stopRecording() else { 
                    resetInputState()
                    return 
                }
                
                guard let service = elevenLabsService else {
                    clippyController.setState(.error, message: "ElevenLabs API Key missing! 🔑")
                    // Don't reset state immediately so user sees message
                    return
                }
                
                Task {
                    do {
                        // 1. Transcribe via ElevenLabs
                        let text = try await service.transcribe(audioFileURL: url)
                        
                        // 2. Feed into existing logic (same as typing)
                        await MainActor.run {
                            if !text.isEmpty {
                                self.processCapturedText(text)
                            } else {
                                self.clippyController.setState(.idle, message: "I didn't catch that 👂")
                                self.activeInputMode = .none
                            }
                        }
                    } catch {
                        await MainActor.run {
                            Logger.ui.error("Voice error: \(error.localizedDescription, privacy: .public)")
                            self.clippyController.setState(.error, message: "Couldn't hear you 🙉")
                            self.activeInputMode = .none
                        }
                    }
                }
            } else {
                resetInputState()
            }
        } else {
            // Switch to Voice Capture Mode
            resetInputState()
            activeInputMode = .voiceCapture
            
            // Check if service is available before starting
            if elevenLabsService == nil {
                clippyController.setState(.idle, message: "Set ElevenLabs API Key in Settings ⚙️")
                // Reset mode after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self.activeInputMode == .voiceCapture {
                        self.resetInputState()
                    }
                }
                return
            }
            
            isRecordingVoice = true
            _ = audioRecorder.startRecording()
            clippyController.setState(.idle, message: "Listening... 🎙️")
        }
    }
    
    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyDown?.flags = .maskCommand
        vKeyUp?.flags = .maskCommand
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
    }
    
    // MARK: - API Key Helpers
    
    private func saveAPIKey(_ key: String) {
        KeychainHelper.save(key: "Gemini_API_Key", value: key)
        geminiService.updateApiKey(key)
    }

    private func getStoredAPIKey() -> String {
        // 1. Check process environment
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty { return envKey }

        // 2. Check Keychain
        if let stored = KeychainHelper.load(key: "Gemini_API_Key"), !stored.isEmpty {
            return stored
        }

        return ""
    }

    private func getStoredElevenLabsKey() -> String {
        // 1. Check process environment
        if let envKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !envKey.isEmpty { return envKey }

        // 2. Check Keychain
        if let stored = KeychainHelper.load(key: "ElevenLabs_API_Key"), !stored.isEmpty {
            return stored
        }

        return ""
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
