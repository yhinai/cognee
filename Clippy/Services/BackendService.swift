import Foundation
import os

// MARK: - Backend Response Models

struct BackendHealthResponse: Codable {
    let status: String
    let services: [String: Bool]
    let models: [String: String]
    let collection: BackendCollectionInfo

    struct BackendCollectionInfo: Codable {
        let name: String
        let points: Int
    }

    enum CodingKeys: String, CodingKey {
        case status, services, models, collection
    }
}

struct BackendSearchResult: Codable, Identifiable {
    let id: String
    let score: Double
    let content: String
    let contentType: String
    let appName: String
    let title: String
    let tags: [String]
}

struct BackendSearchResponse: Codable {
    let query: String?
    let results: [BackendSearchResult]
    let total: Int?
    let timeMs: Double?
    let embedMs: Double?
    let searchMs: Double?
    let method: String?

    enum CodingKeys: String, CodingKey {
        case query, results, total, method
        case timeMs = "time_ms"
        case embedMs = "embed_ms"
        case searchMs = "search_ms"
    }
}

struct BackendGroupedSearchResponse: Codable {
    let query: String?
    let groups: [String: [BackendSearchResult]]
    let total: Int?
    let timeMs: Double?
    let embedMs: Double?
    let searchMs: Double?

    enum CodingKeys: String, CodingKey {
        case query, groups, total
        case timeMs = "time_ms"
        case embedMs = "embed_ms"
        case searchMs = "search_ms"
    }
}

struct BackendDiscoverResponse: Codable {
    let query: String?
    let positiveId: String?
    let negativeId: String?
    let results: [BackendSearchResult]
    let timeMs: Double?
    let embedMs: Double?
    let searchMs: Double?
    let method: String?

    enum CodingKeys: String, CodingKey {
        case query, results, method
        case positiveId = "positive_id"
        case negativeId = "negative_id"
        case timeMs = "time_ms"
        case embedMs = "embed_ms"
        case searchMs = "search_ms"
    }
}

struct BackendAskResponse: Codable {
    let question: String
    let answer: String
    let sources: Int
    let timeMs: Double
    let model: String

    enum CodingKeys: String, CodingKey {
        case question, answer, sources, model
        case timeMs = "time_ms"
    }
}

struct BackendCogneeSearchResponse: Codable {
    let query: String?
    let searchType: String?
    let results: [String]?
    let total: Int?
    let timeMs: Double?
    let method: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case query, results, total, method, error
        case searchType = "search_type"
        case timeMs = "time_ms"
    }
}

struct BackendAddItemResponse: Codable {
    let status: String?
    let pointId: String?
    let timeMs: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, error
        case pointId = "point_id"
        case timeMs = "time_ms"
    }
}

struct BackendAddKnowledgeResponse: Codable {
    let status: String?
    let message: String?
    let timeMs: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, message, error
        case timeMs = "time_ms"
    }
}

struct BackendEntityMatch: Codable {
    let type: String
    let value: String
}

struct BackendExtractEntitiesResponse: Codable {
    let entities: [BackendEntityMatch]
    let total: Int
}

// MARK: - Backend Service

/// HTTP client for the Clippy Python backend (Cognee + Qdrant + Distil Labs SLM).
@MainActor
class BackendService: ObservableObject {
    @Published var isBackendAvailable = false
    @Published var isProcessing = false
    @Published var lastErrorMessage: String?
    @Published var healthInfo: BackendHealthResponse?

    private let baseURL: String
    private let session = URLSession.shared

    init(baseURL: String = "http://localhost:8420") {
        self.baseURL = baseURL
        Task { await checkHealth() }
    }

    // MARK: - Health Check

    func checkHealth() async {
        guard let url = URL(string: "\(baseURL)/health") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                healthInfo = try? decoder.decode(BackendHealthResponse.self, from: data)
                isBackendAvailable = true
                lastErrorMessage = nil
                Logger.services.info("Backend is available")
            } else {
                isBackendAvailable = false
            }
        } catch {
            isBackendAvailable = false
            Logger.services.warning("Backend not available: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Search (Prefetch + RRF Fusion)

    func search(query: String, collection: String = "clippy_items", limit: Int = 20, useFusion: Bool = true) async -> BackendSearchResponse? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/search?q=\(encoded)&collection=\(collection)&limit=\(limit)&use_fusion=\(useFusion)"
        return await getRequest(urlString: urlString)
    }

    // MARK: - Grouped Search

    func searchGrouped(query: String, groupBy: String = "contentType", collection: String = "clippy_items", limit: Int = 20) async -> BackendGroupedSearchResponse? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/search/grouped?q=\(encoded)&collection=\(collection)&group_by=\(groupBy)&limit=\(limit)"
        return await getRequest(urlString: urlString)
    }

    // MARK: - Discovery

    func discover(query: String, positiveId: String? = nil, negativeId: String? = nil, collection: String = "clippy_items", limit: Int = 20) async -> BackendDiscoverResponse? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var urlString = "\(baseURL)/discover?q=\(encoded)&collection=\(collection)&limit=\(limit)"
        if let pid = positiveId {
            urlString += "&positive_id=\(pid)"
        }
        if let nid = negativeId {
            urlString += "&negative_id=\(nid)"
        }
        return await getRequest(urlString: urlString)
    }

    // MARK: - Recommend

    func recommend(positiveIds: [String], negativeIds: [String] = [], collection: String = "clippy_items", strategy: String = "average_vector", limit: Int = 10) async -> BackendSearchResponse? {
        let posStr = positiveIds.joined(separator: ",")
        let negStr = negativeIds.joined(separator: ",")
        let urlString = "\(baseURL)/recommend?positive_ids=\(posStr)&negative_ids=\(negStr)&collection=\(collection)&strategy=\(strategy)&limit=\(limit)"
        return await getRequest(urlString: urlString)
    }

    // MARK: - Ask (RAG Q&A)

    func ask(query: String, collection: String = "clippy_items", limit: Int = 5) async -> BackendAskResponse? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/ask?q=\(encoded)&collection=\(collection)&limit=\(limit)"
        return await getRequest(urlString: urlString)
    }

    // MARK: - Cognee Search

    func cogneeSearch(query: String, searchType: String = "CHUNKS") async -> BackendCogneeSearchResponse? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/cognee-search?q=\(encoded)&search_type=\(searchType)"
        return await getRequest(urlString: urlString)
    }

    // MARK: - Add Knowledge

    func addKnowledge(text: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/add-knowledge") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body = ["text": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return false }
            let result = try JSONDecoder().decode(BackendAddKnowledgeResponse.self, from: data)
            return result.status == "ok"
        } catch {
            Logger.network.error("Add knowledge error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Add Item

    func addItem(content: String, appName: String? = nil, contentType: String = "text", tags: [String] = [], title: String? = nil) async -> Bool {
        guard let url = URL(string: "\(baseURL)/add-item") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "content": content,
            "content_type": contentType,
            "tags": tags,
        ]
        if let appName = appName {
            body["app_name"] = appName
        }
        if let title = title {
            body["title"] = title
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return false }
            let result = try JSONDecoder().decode(BackendAddItemResponse.self, from: data)
            return result.status == "ok"
        } catch {
            Logger.network.error("Add item error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Entity Extraction

    func extractEntities(content: String) async -> [BackendEntityMatch] {
        guard let url = URL(string: "\(baseURL)/extract-entities") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body = ["content": content]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return [] }
            let result = try JSONDecoder().decode(BackendExtractEntitiesResponse.self, from: data)
            return result.entities
        } catch {
            Logger.network.error("Extract entities error: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Collections Info

    func getCollections() async -> [String: Any]? {
        guard let url = URL(string: "\(baseURL)/collections") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Logger.network.error("Collections error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Filtered Search

    func filteredSearch(query: String, typeFilter: String? = nil, appFilter: String? = nil, collection: String = "clippy_items", limit: Int = 20) async -> BackendSearchResponse? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var urlString = "\(baseURL)/filter?q=\(encoded)&collection=\(collection)&limit=\(limit)"
        if let tf = typeFilter {
            urlString += "&type_filter=\(tf)"
        }
        if let af = appFilter {
            urlString += "&app_filter=\(af.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? af)"
        }
        return await getRequest(urlString: urlString)
    }

    // MARK: - Generic GET Helper

    private func getRequest<T: Decodable>(urlString: String) async -> T? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Logger.network.error("Backend GET error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
