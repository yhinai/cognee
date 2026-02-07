import SwiftUI
import SwiftData
import os

enum NavigationCategory: String, Identifiable {
    case allItems = "All Items"
    case favorites = "Favorites"
    case code = "Code"
    case urls = "URLs"
    case images = "Images"
    case sensitive = "Sensitive"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .allItems: return "clock.arrow.circlepath"
        case .favorites: return "heart.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .urls: return "link"
        case .images: return "photo"
        case .sensitive: return "lock.fill"
        }
    }

    static let library: [NavigationCategory] = [.allItems, .favorites]
    static let smart: [NavigationCategory] = [.code, .urls, .images, .sensitive]
}

struct SidebarView: View {
    @Binding var selection: NavigationCategory?
    @Binding var selectedAIService: AIServiceType
    @ObservedObject var clippyController: ClippyWindowController
    @Binding var showSettings: Bool
    @Binding var searchText: String
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var container: AppDependencyContainer
    @Query(sort: \Item.timestamp, order: .reverse) private var allItemsForCounts: [Item]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Library") {
                    ForEach(NavigationCategory.library) { category in
                        NavigationLink(value: category) {
                            HStack {
                                Label(category.rawValue, systemImage: category.iconName)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(countForCategory(category))")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section("Smart") {
                    ForEach(NavigationCategory.smart) { category in
                        let count = countForCategory(category)
                        if count > 0 {
                            NavigationLink(value: category) {
                                HStack {
                                    Label(category.rawValue, systemImage: category.iconName)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text("\(count)")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                if !topApps.isEmpty {
                    Section("Recent Apps") {
                        ForEach(topApps, id: \.self) { appName in
                            Button {
                                selection = .allItems
                                searchText = appName
                            } label: {
                                HStack {
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text(appName)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 12) // Compact top
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            
            // Bottom Panel
            VStack(spacing: 12) {
                // AI Service
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("AI")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Picker("", selection: $selectedAIService) {
                        ForEach(AIServiceType.allCases, id: \.self) { service in
                            Text(service.rawValue).tag(service)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                
                // Model Loading Progress
                if container.localAIService.loadingProgress > 0 && container.localAIService.loadingProgress < 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: container.localAIService.loadingProgress)
                            .tint(.accentColor)
                        Text(container.localAIService.statusMessage)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .ignoresSafeArea(edges: .top)
    }
    
    private func countForCategory(_ category: NavigationCategory) -> Int {
        switch category {
        case .allItems: return allItemsForCounts.count
        case .favorites: return allItemsForCounts.filter { $0.isFavorite }.count
        case .code: return allItemsForCounts.filter { Self.isCodeContent($0) }.count
        case .urls: return allItemsForCounts.filter { Self.isURLContent($0) }.count
        case .images: return allItemsForCounts.filter { $0.contentType == "image" }.count
        case .sensitive: return allItemsForCounts.filter { $0.isSensitive }.count
        }
    }

    private var topApps: [String] {
        let today = Calendar.current.startOfDay(for: Date())
        let todayItems = allItemsForCounts.filter { $0.timestamp >= today }
        var appCounts: [String: Int] = [:]
        for item in todayItems {
            if let app = item.appName, !app.isEmpty, app != "Unknown" {
                appCounts[app, default: 0] += 1
            }
        }
        return appCounts.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
    }

    static func isCodeContent(_ item: Item) -> Bool {
        if item.contentType == "code" { return true }
        let codeKeywords = ["func ", "class ", "struct ", "import ", "var ", "let ", "def ", "return "]
        let hasKeywords = codeKeywords.contains(where: { item.content.contains($0) })
        let hasBraces = item.content.contains("{") && item.content.contains("}")
        return hasKeywords && hasBraces
    }

    static func isURLContent(_ item: Item) -> Bool {
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

}

// MARK: - Keyboard Shortcut Hint View

struct KeyboardShortcutHint: View {
    let keys: String
    let description: String
    
    var body: some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
}
