import Foundation
import SwiftData
import os

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
