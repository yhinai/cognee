import SwiftUI
import SwiftData
import os

struct SearchOverlayView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var container: AppDependencyContainer

    @Query(sort: \Item.timestamp, order: .reverse)
    private var allItems: [Item]

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var semanticResults: [PersistentIdentifier] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSemanticSearching = false
    @FocusState private var isSearchFieldFocused: Bool

    let onDismiss: () -> Void
    let onPaste: (Item) -> Void

    private var displayItems: [Item] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(allItems.prefix(7))
        }

        let query = searchText.lowercased()

        // Text-filtered results
        let textFiltered = allItems.filter { item in
            item.content.localizedCaseInsensitiveContains(query) ||
            (item.title?.localizedCaseInsensitiveContains(query) ?? false) ||
            item.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
            (item.appName?.localizedCaseInsensitiveContains(query) ?? false)
        }

        // Merge semantic results (deduped)
        let textIds = Set(textFiltered.map { $0.persistentModelID })
        let uniqueSemantic = allItems.filter { item in
            semanticResults.contains(item.persistentModelID) && !textIds.contains(item.persistentModelID)
        }

        return Array((textFiltered + uniqueSemantic).prefix(7))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)

                TextField("Search clipboard...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular, design: .rounded))
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel("Search clipboard history")
                    .accessibilityHint("Type to search your clipboard items")
                    .onSubmit {
                        pasteSelectedItem()
                    }

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
                .padding(.horizontal, 16)

            if isSemanticSearching {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Searching semantically...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            // Results
            if displayItems.isEmpty && !searchText.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No results found")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(displayItems.enumerated()), id: \.element.persistentModelID) { index, item in
                                SearchResultRow(
                                    item: item,
                                    index: index + 1,
                                    isSelected: index == selectedIndex
                                )
                                .id(index)
                                .onTapGesture {
                                    onPaste(item)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }

            Divider()
                .padding(.horizontal, 16)

            // Keyboard hints
            HStack(spacing: 20) {
                OverlayKeyHint(keys: ["Return"], action: "Paste")
                OverlayKeyHint(keys: ["\u{2191}\u{2193}"], action: "Navigate")
                OverlayKeyHint(keys: ["Esc"], action: "Close")
                OverlayKeyHint(keys: ["1-7"], action: "Quick select")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 680, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: searchText) { _, newValue in
            selectedIndex = 0
            triggerSemanticSearch(query: newValue)
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < displayItems.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234567")) { press in
            guard let digit = press.characters.first?.wholeNumberValue,
                  digit >= 1, digit <= displayItems.count else {
                return .ignored
            }
            onPaste(displayItems[digit - 1])
            return .handled
        }
    }

    private func pasteSelectedItem() {
        let items = displayItems
        guard selectedIndex >= 0, selectedIndex < items.count else { return }
        onPaste(items[selectedIndex])
    }

    private func triggerSemanticSearch(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            semanticResults = []
            isSemanticSearching = false
            return
        }

        searchTask = Task {
            // Debounce 300ms
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { isSemanticSearching = true }

            let vectorResults = await container.vectorSearch.search(query: trimmed, limit: 7)
            guard !Task.isCancelled else { return }

            // Map vector UUIDs to Items
            let vectorIds = Set(vectorResults.map { $0.0 })
            let matchedIds = allItems.compactMap { item -> PersistentIdentifier? in
                guard let vid = item.vectorId, vectorIds.contains(vid) else { return nil }
                return item.persistentModelID
            }

            await MainActor.run {
                semanticResults = matchedIds
                isSemanticSearching = false
            }
        }
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let item: Item
    let index: Int
    let isSelected: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            // Index badge
            Text("\(index)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                )

            // Content icon
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 20)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    if let appName = item.appName, !appName.isEmpty {
                        Text(appName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Text(Self.relativeFormatter.localizedString(for: item.timestamp, relativeTo: Date()))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))

                    if !item.tags.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(item.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            Spacer()

            // Sensitive indicator
            if item.isSensitive {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isSensitive ? "Sensitive content" : displayText), from \(item.appName ?? "unknown app")")
        .accessibilityHint("Tap to paste this item")
    }

    private var displayText: String {
        if item.isSensitive {
            return String(repeating: "\u{2022}", count: min(item.content.count, 20))
        }
        if item.contentType == "image" {
            return item.title ?? "[Image]"
        }
        let text = item.title ?? item.content
        return String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    private var iconName: String {
        if item.isSensitive { return "lock.fill" }
        switch item.contentType {
        case "image": return "photo"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default:
            if item.content.hasPrefix("http") { return "link" }
            return "doc.text"
        }
    }

    private var iconColor: Color {
        if item.isSensitive { return .orange }
        switch item.contentType {
        case "image": return .blue
        case "code": return .purple
        default:
            if item.content.hasPrefix("http") { return .green }
            return .secondary
        }
    }
}

// MARK: - Keyboard Hint

struct OverlayKeyHint: View {
    let keys: [String]
    let action: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            }
            Text(action)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}
