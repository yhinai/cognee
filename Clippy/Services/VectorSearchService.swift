import Foundation
import SwiftData
import VecturaMLXKit
import VecturaKit
import MLXEmbedders
import os

@MainActor
class VectorSearchService: ObservableObject, VectorSearching {
    @Published var isInitialized = false
    @Published var statusMessage = "Waiting for first use..."

    private weak var backendService: BackendService?
    private var vectorDB: VecturaMLXKit?
    private var pendingVectorItems: [(UUID, String)] = []
    private var isInitializing = false

    /// O(1) lookup from vector IDs to track which documents are indexed
    private var indexedVectorIds: Set<UUID> = []

    init(backendService: BackendService? = nil) {
        self.backendService = backendService
    }

    /// Lazily initialize the VectorDB on first use.
    /// Call sites (addDocument, search) invoke this automatically.
    private func ensureInitialized() async {
        guard vectorDB == nil, !isInitializing else { return }
        isInitializing = true
        statusMessage = "Initializing embedding service..."
        Logger.vector.info("Initializing (lazy, on first use)...")
        do {
            let config = VecturaConfig(
                name: "pastepup-clipboard-v2",
                dimension: nil as Int? // Auto-detect from model
            )

            vectorDB = try await VecturaMLXKit(
                config: config,
                modelConfiguration: .qwen3_embedding
            )

            isInitialized = true
            statusMessage = "Ready (Qwen3-Embedding-0.6B)"
            Logger.vector.info("Initialized successfully with Qwen3")

            // Flush any items that were queued before initialization completed
            if !pendingVectorItems.isEmpty {
                let itemsToFlush = pendingVectorItems
                pendingVectorItems.removeAll()
                Logger.vector.info("Flushing \(itemsToFlush.count, privacy: .public) pending vector items")
                await addDocuments(items: itemsToFlush)
            }
        } catch {
            statusMessage = "Failed to initialize: \(error.localizedDescription)"
            Logger.vector.error("Initialization error: \(error.localizedDescription, privacy: .public)")
        }
        isInitializing = false
    }

    /// Public initialize kept for backward compatibility; now delegates to lazy init.
    func initialize() async {
        await ensureInitialized()
    }
    
    func addDocument(vectorId: UUID, text: String) async {
        await addDocuments(items: [(vectorId, text)])
    }

    func addDocuments(items: [(UUID, String)]) async {
        await ensureInitialized()

        guard let vectorDB = vectorDB else {
            // Queue items for indexing once initialization completes
            pendingVectorItems.append(contentsOf: items)
            Logger.vector.info("Queued \(items.count, privacy: .public) items for later indexing (vectorDB not ready)")
            return
        }
        
        let count = items.count
        Logger.vector.info("Adding \(count, privacy: .public) documents")
        
        do {
            let texts = items.map { $0.1 }
            let ids = items.map { $0.0 }
            
            _ = try await vectorDB.addDocuments(
                texts: texts,
                ids: ids
            )
            indexedVectorIds.formUnion(ids)
            Logger.vector.info("Added \(count, privacy: .public) documents to Vector DB")
        } catch {
            Logger.vector.error("Failed to add documents: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func search(query: String, limit: Int = 10) async -> [(UUID, Float)] {
        // Prefer backend search when available to avoid VecturaMLXKit crash (SIGSEGV in vDSP_dotpr).
        if let backend = backendService {
            if !backend.isBackendAvailable {
                await backend.checkHealth()
            }
            if backend.isBackendAvailable, let response = await backend.search(query: query, limit: limit) {
                let pairs: [(UUID, Float)] = response.results.compactMap { result in
                    guard let uuid = UUID(uuidString: result.id) else { return nil }
                    return (uuid, Float(result.score))
                }
                Logger.vector.info("Backend search: \(pairs.count, privacy: .public) results")
                return pairs
            }
        }

        await ensureInitialized()

        guard let vectorDB = vectorDB else {
            Logger.vector.warning("Cannot search - vectorDB not initialized")
            return []
        }

        Logger.vector.info("Searching local (limit: \(limit, privacy: .public))")

        do {
            let results = try await vectorDB.search(
                query: query,
                numResults: limit,
                threshold: nil
            )

            Logger.vector.info("Found \(results.count, privacy: .public) results")
            return results.map { ($0.id, $0.score) }
        } catch {
            Logger.vector.error("Search error: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
    
    func deleteDocument(vectorId: UUID) async throws {
        pendingVectorItems.removeAll { $0.0 == vectorId }
        indexedVectorIds.remove(vectorId)

        guard let vectorDB = vectorDB else { return }

        try await vectorDB.deleteDocuments(ids: [vectorId])
    }

    /// O(1) check if a vector ID is indexed.
    func isIndexed(vectorId: UUID) -> Bool {
        indexedVectorIds.contains(vectorId)
    }

    /// Filter a list of vector IDs to only those that are indexed. O(n) where n = input size.
    func filterIndexed(vectorIds: [UUID]) -> [UUID] {
        vectorIds.filter { indexedVectorIds.contains($0) }
    }
}
