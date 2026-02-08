import Foundation
import SwiftData

// MARK: - Vector Search Protocol

@MainActor
protocol VectorSearching {
    var isInitialized: Bool { get }
    func initialize() async
    func addDocument(vectorId: UUID, text: String) async
    func addDocuments(items: [(UUID, String)]) async
    func search(query: String, limit: Int) async -> [(UUID, Float)]
    func deleteDocument(vectorId: UUID) async throws
}
