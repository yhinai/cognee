import Foundation
import os

/// Tracks AI API usage per provider with estimated costs.
@MainActor
class UsageTracker: ObservableObject {

    struct UsageRecord: Codable {
        let providerId: String
        let timestamp: Date
        let estimatedTokens: Int
        let estimatedCost: Double
    }

    @Published var todayCalls: Int = 0
    @Published var todayCost: Double = 0.0
    @Published var perProviderToday: [String: (calls: Int, cost: Double)] = [:]

    private var records: [UsageRecord] = []
    private let storageKey = "ClippyUsageRecords"

    // Estimated cost per 1K tokens (input+output blended)
    private let pricing: [String: Double] = [
        "gemini": 0.0005,   // Gemini 2.5 Flash
        "claude": 0.003,    // Claude Sonnet
        "openai": 0.0003,   // GPT-4o Mini
        "ollama": 0.0,      // Free (local)
        "local":  0.0       // Free (on-device)
    ]

    init() {
        loadRecords()
        refreshStats()
    }

    /// Record an API call.
    func recordCall(providerId: String, estimatedTokens: Int) {
        let costPer1K = pricing[providerId] ?? 0.0
        let cost = Double(estimatedTokens) / 1000.0 * costPer1K

        let record = UsageRecord(
            providerId: providerId,
            timestamp: Date(),
            estimatedTokens: estimatedTokens,
            estimatedCost: cost
        )
        records.append(record)
        saveRecords()
        refreshStats()
    }

    /// Get cost summary for a date range.
    func costSummary(from startDate: Date, to endDate: Date = Date()) -> Double {
        records
            .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
            .reduce(0) { $0 + $1.estimatedCost }
    }

    func callCount(from startDate: Date, to endDate: Date = Date()) -> Int {
        records.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }.count
    }

    // MARK: - Private

    private func refreshStats() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todayRecords = records.filter { $0.timestamp >= startOfDay }

        todayCalls = todayRecords.count
        todayCost = todayRecords.reduce(0) { $0 + $1.estimatedCost }

        var breakdown: [String: (calls: Int, cost: Double)] = [:]
        for record in todayRecords {
            let existing = breakdown[record.providerId] ?? (calls: 0, cost: 0.0)
            breakdown[record.providerId] = (calls: existing.calls + 1, cost: existing.cost + record.estimatedCost)
        }
        perProviderToday = breakdown
    }

    private func saveRecords() {
        // Keep only last 30 days of records
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        records = records.filter { $0.timestamp >= cutoff }

        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([UsageRecord].self, from: data) else { return }
        records = decoded
    }
}
