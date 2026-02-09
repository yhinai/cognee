import Foundation
import SwiftData
import os

@MainActor
class AppDependencyContainer: ObservableObject {
    // Core Services
    let vectorSearch: VectorSearchService
    let clipboardMonitor: ClipboardMonitor
    let contextEngine: ContextEngine
    let visionParser: VisionScreenParser
    let hotkeyManager: HotkeyManager
    let textCaptureService: TextCaptureService
    let clippyController: ClippyWindowController
    let searchOverlayController: SearchOverlayController

    // AI Services
    let localAIService: LocalAIService
    let geminiProvider: GeminiProvider
    let audioRecorder: AudioRecorder
    let queryOrchestrator: QueryOrchestrator
    let usageTracker: UsageTracker
    let ragService: RAGService

    // Backend (Cognee + Qdrant + SLM)
    let backendService: BackendService

    // Multi-provider AI
    let claudeProvider: ClaudeProvider
    let openAIProvider: OpenAIProvider
    let ollamaProvider: OllamaProvider
    let aiRegistry: AIProviderRegistry
    let aiRouter: AIRouter

    /// Currently selected AI service (persisted in UserDefaults)
    @Published var selectedAIServiceType: AIServiceType {
        didSet {
            UserDefaults.standard.set(selectedAIServiceType.rawValue, forKey: "SelectedAIService")
        }
    }

    // Data Layer
    var repository: ClipboardRepository?

    init() {
        Logger.services.info("Initializing services...")

        // Load persisted AI service selection
        let initialServiceType: AIServiceType
        if let saved = UserDefaults.standard.string(forKey: "SelectedAIService"),
           let savedType = AIServiceType(rawValue: saved) {
            initialServiceType = savedType
        } else {
            initialServiceType = .local
        }
        self.selectedAIServiceType = initialServiceType

        // 1. Initialize Independent Services (backend first so vector search can use it)
        self.backendService = BackendService()
        self.vectorSearch = VectorSearchService(backendService: backendService)
        self.contextEngine = ContextEngine()
        self.visionParser = VisionScreenParser()
        self.hotkeyManager = HotkeyManager()
        self.clippyController = ClippyWindowController()
        self.searchOverlayController = SearchOverlayController()
        self.audioRecorder = AudioRecorder()
        self.localAIService = LocalAIService()
        self.usageTracker = UsageTracker()
        self.geminiProvider = GeminiProvider()
        self.textCaptureService = TextCaptureService()
        self.ragService = RAGService(localAI: localAIService)

        // 2. Multi-provider AI setup
        self.claudeProvider = ClaudeProvider()
        self.openAIProvider = OpenAIProvider()
        self.ollamaProvider = OllamaProvider()

        let registry = AIProviderRegistry()
        self.aiRegistry = registry

        // Determine preferred provider from persisted selection
        let preferredId: String
        switch initialServiceType {
        case .claude: preferredId = "claude"
        case .openai: preferredId = "openai"
        case .ollama: preferredId = "ollama"
        case .gemini: preferredId = "gemini"
        case .local:  preferredId = "local"
        case .backend: preferredId = "backend"
        }
        self.aiRouter = AIRouter(registry: registry, preferredProviderId: preferredId)

        // 3. Initialize Dependent Services
        self.clipboardMonitor = ClipboardMonitor()
        self.queryOrchestrator = QueryOrchestrator(
            vectorSearch: vectorSearch,
            geminiProvider: geminiProvider,
            localAIService: localAIService
        )

        // 4. Register all providers
        registry.register(claudeProvider)
        registry.register(openAIProvider)
        registry.register(ollamaProvider)
        registry.register(geminiProvider)

        // Wire AIRouter, UsageTracker, and BackendService into QueryOrchestrator
        queryOrchestrator.aiRouter = aiRouter
        queryOrchestrator.usageTracker = usageTracker
        queryOrchestrator.backendService = backendService
        queryOrchestrator.ragService = ragService

        // Detect Ollama availability in background
        Task { await ollamaProvider.detectAvailability() }

        Logger.services.info("Services initialized.")
    }
    
    func inject(modelContext: ModelContext) {
        Logger.services.info("Injecting ModelContext and cross-service dependencies")
        
        // Initialize Repository
        self.repository = SwiftDataClipboardRepository(modelContext: modelContext, vectorService: vectorSearch)
        
        // Inject dependencies into ClipboardMonitor
        if let repo = self.repository {
            clipboardMonitor.startMonitoring(
                repository: repo,
                contextEngine: contextEngine,
                geminiProvider: geminiProvider,
                localAIService: localAIService,
                backendService: backendService
            )
        }
        
        // Inject dependencies into TextCaptureService
        textCaptureService.setDependencies(
            clippyController: clippyController,
            clipboardMonitor: clipboardMonitor
        )
    }
}
