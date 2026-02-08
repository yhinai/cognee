import AppKit
import Foundation
import SwiftData
import os

/// ClipboardMonitor: Thin orchestrator for clipboard events.
/// Delegates context to ContextEngine, ingestion to Repository.
@MainActor
class ClipboardMonitor: ObservableObject {
    @Published var clipboardContent: String = ""
    @Published var isMonitoring: Bool = false

    /// Set to true before programmatically writing to the clipboard to prevent re-ingesting our own copy.
    var skipNextClipboardChange: Bool = false

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var repository: ClipboardRepository?
    private var contextEngine: ContextEngine?
    private var geminiService: GeminiService?
    private var localAIService: LocalAIService?
    private var backendService: BackendService?

    // Adaptive polling: fast after clipboard change, slow when idle
    private var currentPollingInterval: TimeInterval = 0.3
    private let minPollingInterval: TimeInterval = 0.3
    private let maxPollingInterval: TimeInterval = 2.0
    private let pollingBackoffMultiplier: Double = 1.2
    
    // MARK: - Computed Properties (delegated to ContextEngine)
    
    var currentAppName: String { contextEngine?.currentAppName ?? "Unknown" }
    var currentWindowTitle: String { contextEngine?.currentWindowTitle ?? "" }
    var hasAccessibilityPermission: Bool { contextEngine?.hasAccessibilityPermission ?? false }
    var accessibilityContext: String { contextEngine?.accessibilityContext ?? "" }

    // MARK: - Lifecycle
    
    func startMonitoring(
        repository: ClipboardRepository,
        contextEngine: ContextEngine,
        geminiService: GeminiService? = nil,
        localAIService: LocalAIService? = nil,
        backendService: BackendService? = nil
    ) {
        self.repository = repository
        self.contextEngine = contextEngine
        self.geminiService = geminiService
        self.localAIService = localAIService
        self.backendService = backendService
        
        // Initialize lastChangeCount to avoid processing existing content
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        
        if let string = pasteboard.string(forType: .string) {
            clipboardContent = string
        }
        
        isMonitoring = true

        // Start monitoring with adaptive polling
        scheduleNextPoll()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    /// Schedule the next clipboard poll with adaptive interval.
    /// After a change: resets to fast polling (0.3s).
    /// While idle: gradually increases to slow polling (2.0s) to save CPU.
    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: currentPollingInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isMonitoring else { return }
                let changed = self.checkClipboardAndReportChange()
                if changed {
                    self.contextEngine?.updateContext()
                    self.currentPollingInterval = self.minPollingInterval
                } else {
                    self.currentPollingInterval = min(
                        self.currentPollingInterval * self.pollingBackoffMultiplier,
                        self.maxPollingInterval
                    )
                }
                self.scheduleNextPoll()
            }
        }
    }
    
    func requestAccessibilityPermission() {
        contextEngine?.requestAccessibilityPermission()
    }
    
    func openSystemPreferences() {
        contextEngine?.openSystemPreferences()
    }
    
    func getRichContext() -> String {
        contextEngine?.getRichContext(clipboardContent: clipboardContent) ?? ""
    }
    
    // MARK: - Clipboard Detection

    /// Check clipboard and return whether a change was detected (for adaptive polling).
    @discardableResult
    private func checkClipboardAndReportChange() -> Bool {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard currentChangeCount != lastChangeCount else { return false }
        lastChangeCount = currentChangeCount

        // Skip this change if it was triggered by the app itself (e.g. status bar copy)
        if skipNextClipboardChange {
            skipNextClipboardChange = false
            return true
        }

        // Check for images first
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            clipboardContent = "[Image]"
            saveImageItem(imageData: imageData)
        }
        // Then check for text
        else if let string = pasteboard.string(forType: .string) {
            clipboardContent = string
            saveClipboardItem(content: string)
        } else {
            clipboardContent = ""
        }

        return true
    }
    
    // MARK: - Image Handling
    
    private func saveImageItem(imageData: Data) {
        guard let repository = repository else { return }
        
        Logger.clipboard.info("Saving new image item")
        
        guard let nsImage = NSImage(data: imageData),
              let pngData = nsImage.pngData() else {
            Logger.clipboard.error("Failed to convert image to PNG format")
            return
        }
        
        let filename = "\(UUID().uuidString).png"
        let imageURL = ClipboardService.shared.getImagesDirectory().appendingPathComponent(filename)
        
        do {
            try pngData.write(to: imageURL)
        } catch {
            Logger.clipboard.error("Failed to save image to disk: \(error.localizedDescription, privacy: .public)")
            return
        }
        
        let vectorId = UUID()
        Task {
            do {
                let newItem = try await repository.saveItem(
                    content: "Analyzing image... 🖼️",
                    appName: currentAppName.isEmpty ? "Unknown" : currentAppName,
                    contentType: "image",
                    timestamp: Date(),
                    tags: [],
                    vectorId: vectorId,
                    imagePath: filename,
                    title: "Processing...",
                    isSensitive: false,
                    expiresAt: nil
                )
                Logger.clipboard.info("Image placeholder saved")
                enhanceImageItem(newItem, pngData: pngData)
            } catch {
                Logger.clipboard.error("Failed to save image item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func enhanceImageItem(_ item: Item, pngData: Data) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            var title: String?
            var description: String = "[Image]"
            
            if let localService = await self.localAIService {
                let base64Image = pngData.base64EncodedString()
                if let localDesc = await localService.generateVisionDescription(base64Image: base64Image, screenText: nil) {
                    description = localDesc
                    if localDesc.contains("Title:") {
                        let lines = localDesc.split(separator: "\n")
                        if let titleLine = lines.first(where: { $0.hasPrefix("Title:") }) {
                            title = String(titleLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            } else if let gemini = await self.geminiService {
                description = await gemini.analyzeImage(imageData: pngData) ?? "[Image]"
            }
            
            let finalDescription = description
            let finalTitle = title
            await MainActor.run {
                item.content = finalDescription
                item.title = finalTitle
            }
            
            if let repo = await self.repository {
                try? await repo.updateItem(item)
                Logger.clipboard.info("Image analysis complete")
            }
            
            await self.enhanceItem(item)
        }
    }
    
    // MARK: - Text Handling
    
    private func saveClipboardItem(content: String) {
        guard let repository = repository else { return }
        
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty || trimmedContent.count < 3 { return }
        
        // Filter debug content
        let debugPatterns = ["⌨️", "🎯", "✅", "❌", "📤", "📡", "📄", "💾", "🏷️", "🤖", "🛑", "🔄"]
        let logPatterns = ["[HotkeyManager]", "[ContentView]", "[TextCaptureService]", "[GeminiService]", "[ClipboardMonitor]", "[EmbeddingService]"]
        if debugPatterns.contains(where: { trimmedContent.contains($0) }) || logPatterns.contains(where: { trimmedContent.contains($0) }) {
            return
        }
        
        if repository.findDuplicate(content: content) != nil {
            Logger.clipboard.debug("Skipping duplicate content")
            return
        }
        
        Logger.clipboard.info("Saving new clipboard item")

        let isSensitive = SensitiveContentDetector.isSensitive(trimmedContent)
        let vectorId = UUID()
        Task {
            do {
                let newItem = try await repository.saveItem(
                    content: content,
                    appName: currentAppName.isEmpty ? "Unknown" : currentAppName,
                    contentType: "text",
                    timestamp: Date(),
                    tags: [],
                    vectorId: vectorId,
                    imagePath: nil,
                    title: nil,
                    isSensitive: isSensitive,
                    expiresAt: isSensitive ? Date().addingTimeInterval(3600) : nil
                )

                Logger.clipboard.info("Item saved (sensitive: \(isSensitive, privacy: .public))")
                // Auto-index to Qdrant via backend (if available)
                if !isSensitive, let backend = self.backendService, backend.isBackendAvailable {
                    Task {
                        let _ = await backend.addItem(
                            content: content,
                            appName: self.currentAppName.isEmpty ? nil : self.currentAppName,
                            contentType: "text"
                        )
                    }
                }
                // Skip AI tag generation for sensitive content
                if !isSensitive {
                    enhanceItem(newItem)
                }
            } catch {
                Logger.clipboard.error("Failed to save: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // MARK: - AI Enhancement

    private func enhanceItem(_ item: Item) {
        let content = item.content
        let appName = item.appName
        let needsTitle = item.title == nil && content.count > 100

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            var tags: [String] = []

            if let localService = await self.localAIService {
                tags = await Task { @MainActor in
                    await localService.generateTags(content: content, appName: appName, context: nil)
                }.value
            } else if let gemini = await self.geminiService {
                tags = await Task { @MainActor in
                    await gemini.generateTags(content: content, appName: appName, context: nil)
                }.value
            }

            // Auto-generate a title for long items that don't have one
            var generatedTitle: String?
            if needsTitle {
                // Use first non-empty line, truncated to 50 chars
                let firstLine = content.split(separator: "\n", maxSplits: 1).first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !firstLine.isEmpty {
                    generatedTitle = String(firstLine.prefix(50))
                    if firstLine.count > 50 {
                        generatedTitle?.append("...")
                    }
                }
            }

            let finalTags = tags
            let finalGeneratedTitle = generatedTitle
            let shouldUpdate = !finalTags.isEmpty || finalGeneratedTitle != nil
            if shouldUpdate, let repo = await self.repository {
                await MainActor.run {
                    if !finalTags.isEmpty {
                        item.tags = finalTags
                    }
                    if let title = finalGeneratedTitle, item.title == nil {
                        item.title = title
                    }
                    Task {
                        try? await repo.updateItem(item)
                        Logger.clipboard.info("Enhanced item (tags: \(finalTags.count, privacy: .public), title: \(finalGeneratedTitle != nil, privacy: .public))")
                    }
                }
            }
        }
    }
}

// MARK: - NSImage PNG Extension

extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }
}

// MARK: - Clipboard Service (Copy/Paste Operations)

class ClipboardService {
    static let shared = ClipboardService()
    
    private init() {}
    
    func getImagesDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let imagesDir = appSupport.appendingPathComponent("Clippy/Images")
        if !FileManager.default.fileExists(atPath: imagesDir.path) {
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }
        return imagesDir
    }

    func loadImage(from path: String) -> NSImage? {
        let imageURL = getImagesDirectory().appendingPathComponent(path)
        return NSImage(contentsOf: imageURL)
    }

    func copyImageToClipboard(imagePath: String) {
        let imageURL = getImagesDirectory().appendingPathComponent(imagePath)
        guard let nsImage = NSImage(contentsOf: imageURL) else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }
    
    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}



@MainActor
protocol ClipboardRepository {
    func saveItem(
        content: String,
        appName: String,
        contentType: String,
        timestamp: Date,
        tags: [String],
        vectorId: UUID?,
        imagePath: String?,
        title: String?,
        isSensitive: Bool,
        expiresAt: Date?
    ) async throws -> Item

    func deleteItem(_ item: Item) async throws

    func updateItem(_ item: Item) async throws

    func findDuplicate(content: String) -> Item?

    /// Delete non-favorite items whose expiresAt date has passed.
    func purgeExpiredItems() async
}

@MainActor
class SwiftDataClipboardRepository: ClipboardRepository {
    private let modelContext: ModelContext
    private let vectorService: VectorSearchService // The vector DB service
    private var purgeTimer: Timer?

    init(modelContext: ModelContext, vectorService: VectorSearchService) {
        self.modelContext = modelContext
        self.vectorService = vectorService

        // Purge expired items on launch and every 15 minutes
        Task { await self.purgeExpiredItems() }
        self.purgeTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.purgeExpiredItems()
            }
        }
    }
    
    func saveItem(
        content: String,
        appName: String,
        contentType: String = "text",
        timestamp: Date = Date(),
        tags: [String] = [],
        vectorId: UUID? = nil,
        imagePath: String? = nil,
        title: String? = nil,
        isSensitive: Bool = false,
        expiresAt: Date? = nil
    ) async throws -> Item {
        // 1. Create the SwiftData Item
        // Note: Init uses defaults for some fields, we set others after if needed
        let newItem = Item(
            timestamp: timestamp,
            content: content,
            title: title,
            appName: appName,
            contentType: contentType,
            imagePath: imagePath
        )
        newItem.tags = tags
        newItem.isSensitiveFlag = isSensitive
        newItem.expiresAt = expiresAt

        // 2. Add to Vector DB
        // If vectorId is provided, use it. Otherwise generate one.
        let finalVectorId = vectorId ?? UUID()
        newItem.vectorId = finalVectorId

        // Skip vector DB embedding for sensitive content
        if !isSensitive {
            // Combine Title and Content for search embedding so both are searchable
            // Logic mirrored from ClipboardMonitor
            let embeddingText = (title != nil && !title!.isEmpty) ? "\(title!)\n\n\(content)" : content

            await vectorService.addDocument(vectorId: finalVectorId, text: embeddingText)
        }

        // 3. Save to SwiftData
        modelContext.insert(newItem)

        // Note: Autosave is usually enabled, but we can force it if needed.
        // try modelContext.save()

        Logger.clipboard.info("Saved item: \(title ?? "No Title", privacy: .private) (ID: \(finalVectorId.uuidString, privacy: .private))")
        return newItem
    }
    
    func deleteItem(_ item: Item) async throws {
        // 1. Remove image file from disk
        if let imagePath = item.imagePath {
            let imageURL = ClipboardService.shared.getImagesDirectory().appendingPathComponent(imagePath)
            try? FileManager.default.removeItem(at: imageURL)
        }

        // 2. Remove from Vector DB
        if let vectorId = item.vectorId {
             try? await vectorService.deleteDocument(vectorId: vectorId)
        }

        // 3. Remove from SwiftData
        modelContext.delete(item)
    }
    
    func updateItem(_ item: Item) async throws {
        // 1. Save SwiftData changes
        try modelContext.save()
        
        // 2. Update Vector DB
        if let vectorId = item.vectorId {
            let embeddingText = (item.title != nil && !item.title!.isEmpty) ? "\(item.title!)\n\n\(item.content)" : item.content
            
             // VectorSearchService.addDocument overwrites if ID exists (upsert)
            await vectorService.addDocument(vectorId: vectorId, text: embeddingText)
            Logger.clipboard.info("Updated item and re-indexed vector: \(item.title ?? "Untitled", privacy: .private)")
        }
    }
    
    func findDuplicate(content: String) -> Item? {
        let fetchDescriptor = FetchDescriptor<Item>(
            predicate: #Predicate<Item> { item in
                item.content == content
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try? modelContext.fetch(fetchDescriptor).first
    }

    func purgeExpiredItems() async {
        let now = Date()
        let fetchDescriptor = FetchDescriptor<Item>(
            predicate: #Predicate<Item> { item in
                item.expiresAt != nil && item.isFavorite == false
            }
        )

        guard let expiredCandidates = try? modelContext.fetch(fetchDescriptor) else { return }

        // Filter in-memory since #Predicate doesn't support Date comparison with a captured variable
        let expired = expiredCandidates.filter { item in
            guard let expiresAt = item.expiresAt else { return false }
            return expiresAt < now
        }

        guard !expired.isEmpty else { return }
        Logger.clipboard.info("Purging \(expired.count, privacy: .public) expired items")

        for item in expired {
            try? await deleteItem(item)
        }
    }
}
