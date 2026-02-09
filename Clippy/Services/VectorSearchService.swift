import Foundation
import MLXEmbedders
import SwiftData
import VecturaKit
import VecturaMLXKit
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

    // MARK: - Direct Qdrant REST API (for Python backend replacement)

    private let qdrantBaseURL = "http://localhost:6333"
    private let qdrantCollection = "clippy_items"

    /// Upsert a point directly to Qdrant via REST API.
    func upsertToQdrant(
        pointId: String,
        vector: [Float],
        payload: [String: Any]
    ) async -> Bool {
        guard let url = URL(string: "\(qdrantBaseURL)/collections/\(qdrantCollection)/points?wait=true") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "points": [[
                "id": pointId,
                "vector": vector,
                "payload": payload
            ]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                Logger.vector.info("Upserted point \(pointId, privacy: .public) to Qdrant")
                return true
            }
        } catch {
            Logger.vector.error("Qdrant upsert error: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    /// Search Qdrant directly via REST API with optional filters.
    func searchQdrant(
        vector: [Float],
        limit: Int = 10,
        filter: [String: Any]? = nil
    ) async -> [QdrantSearchResult] {
        guard let url = URL(string: "\(qdrantBaseURL)/collections/\(qdrantCollection)/points/search") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "vector": vector,
            "limit": limit,
            "with_payload": true
        ]
        if let filter = filter {
            body["filter"] = filter
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["result"] as? [[String: Any]] {
                return results.compactMap { QdrantSearchResult(from: $0) }
            }
        } catch {
            Logger.vector.error("Qdrant search error: \(error.localizedDescription, privacy: .public)")
        }
        return []
    }

    /// Ensure the Qdrant collection exists.
    func ensureQdrantCollection(dimension: Int = 896) async -> Bool {
        // Check if collection exists
        guard let checkURL = URL(string: "\(qdrantBaseURL)/collections/\(qdrantCollection)") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: checkURL)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                Logger.vector.info("Qdrant collection '\(self.qdrantCollection, privacy: .public)' exists")
                return true
            }
        } catch {
            // Collection doesn't exist, create it
        }

        // Create collection
        guard let createURL = URL(string: "\(qdrantBaseURL)/collections/\(qdrantCollection)") else {
            return false
        }

        var request = URLRequest(url: createURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "vectors": [
                "size": dimension,
                "distance": "Cosine"
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                Logger.vector.info("Created Qdrant collection '\(self.qdrantCollection, privacy: .public)'")
                return true
            }
        } catch {
            Logger.vector.error("Qdrant create collection error: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }
}

// MARK: - Qdrant Models

struct QdrantSearchResult {
    let id: String
    let score: Float
    let content: String
    let contentType: String
    let appName: String
    let title: String
    let tags: [String]

    init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? String ?? (dict["id"] as? Int).map({ String($0) }),
              let score = (dict["score"] as? Double).map({ Float($0) }) ?? (dict["score"] as? Float) else {
            return nil
        }
        self.id = id
        self.score = score

        let payload = dict["payload"] as? [String: Any] ?? [:]
        self.content = payload["content"] as? String ?? ""
        self.contentType = payload["contentType"] as? String ?? "text"
        self.appName = payload["appName"] as? String ?? ""
        self.title = payload["title"] as? String ?? ""
        self.tags = payload["tags"] as? [String] ?? []
    }
}
