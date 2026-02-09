import SwiftData
import SwiftUI

struct ClipboardListView: View {
    @Binding var selectedItems: Set<PersistentIdentifier>
    var category: NavigationCategory?
    @Binding var searchText: String
    
    @EnvironmentObject var container: AppDependencyContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Item.timestamp, order: .reverse) private var allItems: [Item]
    
    @State private var searchResults: [Item] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var copiedItemId: PersistentIdentifier?
    @State private var keyboardIndex: Int = 0
    
    var body: some View {
        VStack(spacing: 0) {
            itemList
        }
        .onChange(of: searchText) { _, newValue in
            handleSearchChange(newValue)
        }
    }

    @ViewBuilder
    private var itemList: some View {
        List(selection: $selectedItems) {
            listContent
        }
        .listStyle(.plain)
        .navigationTitle(category?.rawValue ?? "Clipboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                GlassSearchBar(searchText: $searchText)
                    .frame(width: 320)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onKeyPress(.escape) { handleEscapeKey() }
        .onKeyPress(.upArrow) { handleUpArrowKey() }
        .onKeyPress(.downArrow) { handleDownArrowKey() }
        .onKeyPress(.return) { handleReturnKey() }
        .onKeyPress(.delete, phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            return handleDeleteKey()
        }
        .onKeyPress("d", phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.command) else { return .ignored }
            return handleFavoriteKey()
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if searchText.isEmpty {
            ForEach(filteredItems) { item in
                clipboardRow(for: item)
            }
        } else if isSearching {
            HStack {
                Spacer()
                ProgressView("Searching...")
                    .scaleEffect(0.8)
                Spacer()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else if searchResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            ForEach(searchResults) { item in
                clipboardRow(for: item)
            }
        }
    }

    // MARK: - Key Press Handlers

    private func handleEscapeKey() -> KeyPress.Result {
        if !selectedItems.isEmpty {
            Task { @MainActor in
                await Task.yield()  // Break to next runloop to avoid reentrant table view
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedItems.removeAll()
                }
            }
            return .handled
        }
        return .ignored
    }

    private func handleUpArrowKey() -> KeyPress.Result {
        let items = currentItems
        guard !items.isEmpty else { return .handled }
        // Clamp current index to valid range in case list shrank
        let safeIndex = min(keyboardIndex, items.count - 1)
        guard safeIndex > 0 else { return .handled }
        let newIndex = safeIndex - 1
        let itemId = items[newIndex].persistentModelID
        Task { @MainActor in
            await Task.yield()
            keyboardIndex = newIndex
            selectedItems = [itemId]
        }
        return .handled
    }

    private func handleDownArrowKey() -> KeyPress.Result {
        let items = currentItems
        guard !items.isEmpty else { return .handled }
        // Clamp current index to valid range in case list shrank
        let safeIndex = min(keyboardIndex, items.count - 1)
        guard safeIndex < items.count - 1 else { return .handled }
        let newIndex = safeIndex + 1
        let itemId = items[newIndex].persistentModelID
        Task { @MainActor in
            await Task.yield()
            keyboardIndex = newIndex
            selectedItems = [itemId]
        }
        return .handled
    }

    private func handleReturnKey() -> KeyPress.Result {
        let items = currentItems
        if keyboardIndex >= 0, keyboardIndex < items.count {
            copyToClipboard(items[keyboardIndex])
        }
        return .handled
    }

    private func handleDeleteKey() -> KeyPress.Result {
        let items = currentItems
        if keyboardIndex >= 0, keyboardIndex < items.count {
            deleteItem(items[keyboardIndex])
        }
        return .handled
    }

    private func handleFavoriteKey() -> KeyPress.Result {
        let items = currentItems
        guard keyboardIndex >= 0, keyboardIndex < items.count else { return .handled }
        let item = items[keyboardIndex]
        Task { @MainActor in
            await Task.yield()
            item.isFavorite.toggle()
        }
        return .handled
    }

    private func handleSearchChange(_ newValue: String) {
        searchTask?.cancel()

        guard !newValue.isEmpty else {
            Task { @MainActor in
                await Task.yield()
                self.searchResults = []
                self.isSearching = false
            }
            return
        }

        // Defer isSearching change to next runloop
        Task { @MainActor in
            await Task.yield()
            isSearching = true
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            let results = await container.vectorSearch.search(query: newValue, limit: 20)
            if Task.isCancelled { return }

            let ids = results.map { $0.0 }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                let foundItems = self.allItems.filter { ids.contains($0.vectorId ?? UUID()) }
                self.searchResults = ids.compactMap { id in
                    foundItems.first(where: { $0.vectorId == id })
                }
                self.isSearching = false
            }
        }
    }
    
    // Filter items based on category (when not searching)
    private var filteredItems: [Item] {
        guard let category = category else { return allItems }
        switch category {
        case .allItems: return allItems
        case .favorites: return allItems.filter { $0.isFavorite }
        case .code: return allItems.filter { $0.isCodeContent }
        case .urls: return allItems.filter { $0.isURLContent }
        case .images: return allItems.filter { $0.contentType == "image" }
        case .sensitive: return allItems.filter { $0.isSensitive }
        }
    }

    // Active items list (search results or filtered)
    private var currentItems: [Item] {
        searchText.isEmpty ? filteredItems : searchResults
    }



    // MARK: - Shared Row Builder

    @ViewBuilder
    private func clipboardRow(for item: Item) -> some View {
        ClipboardItemRow(
            item: item,
            isSelected: selectedItems.contains(item.persistentModelID),
            isCopied: copiedItemId == item.persistentModelID
        )
            .tag(item.persistentModelID)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button {
                    copyToClipboard(item)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    Task { @MainActor in
                        item.isFavorite.toggle()
                    }
                } label: {
                    Label(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "heart.slash" : "heart")
                }

                Divider()

                Button {
                    performTransform(item, instruction: "Fix grammar and spelling.")
                } label: {
                    Label("Fix Grammar", systemImage: "text.badge.checkmark")
                }

                Button {
                    performTransform(item, instruction: "Summarize this text in one sentence.")
                } label: {
                    Label("Summarize", systemImage: "text.quote")
                }

                Button {
                    performTransform(item, instruction: "Convert this to valid JSON.")
                } label: {
                    Label("To JSON", systemImage: "curlybraces")
                }

                Divider()

                Button(role: .destructive) {
                    deleteItem(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    // MARK: - Helper Methods

    private func performTransform(_ item: Item, instruction: String) {
        Task {
            guard let result = await container.localAIService.transformText(text: item.content, instruction: instruction) else { return }
            await MainActor.run {
                container.clipboardMonitor.skipNextClipboardChange = true
                ClipboardService.shared.copyTextToClipboard(result)
            }
        }
    }
    
    private func copyToClipboard(_ item: Item) {
        container.clipboardMonitor.skipNextClipboardChange = true

        if item.contentType == "image", let imagePath = item.imagePath {
            ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
        } else {
            ClipboardService.shared.copyTextToClipboard(item.content)
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            copiedItemId = item.persistentModelID
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation {
                    if copiedItemId == item.persistentModelID {
                        copiedItemId = nil
                    }
                }
            }
        }
    }
    
    private func deleteItem(_ item: Item) {
        let vectorId = item.vectorId
        Task {
            await Task.yield()  // Break to next runloop
            await MainActor.run {
                modelContext.delete(item)
                // Clamp keyboardIndex to avoid pointing past last item
                let remaining = max(0, currentItems.count - 1)
                if keyboardIndex > remaining {
                    keyboardIndex = remaining
                }
            }
            // Remove from vector store in background (non-blocking)
            try? await container.vectorSearch.deleteDocument(vectorId: vectorId ?? UUID())
        }
    }
}

// MARK: - Clipboard Item Row

struct ClipboardItemRow: View {
    let item: Item
    let isSelected: Bool
    var isCopied: Bool = false
    @State private var isHovering = false

    private var isCode: Bool { item.isCodeContent }
    private var isURL: Bool { item.isURLContent }

    private var urlDomain: String? {
        guard isURL else { return nil }
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.components(separatedBy: "\n").first ?? trimmed)?.host
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Icon or image thumbnail
            if item.contentType == "image", let imagePath = item.imagePath {
                let imageURL = ClipboardService.shared.getImagesDirectory().appendingPathComponent(imagePath)
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Circle().fill(richIconGradient)
                        Image(systemName: "photo")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                ZStack {
                    Circle()
                        .fill(isCopied ? LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing) : richIconGradient)
                        .frame(width: 26, height: 26)

                    Image(systemName: isCopied ? "checkmark" : richIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // Title with content-aware font — 2-line limit for all types
                if item.isSensitive {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text("Sensitive content")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundColor(.orange)
                    }
                } else if isCopied {
                    Text("Copied!")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(.green)
                } else if isCode {
                    Text(item.title ?? String(item.content.prefix(120)).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundColor(.purple)
                        .lineLimit(2)
                } else if isURL, let domain = urlDomain {
                    Text(domain)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(.teal)
                        .lineLimit(2)
                } else {
                    Text(item.title ?? item.content)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                // Content preview (1 line, lighter color) — skip for sensitive/copied/image
                if !item.isSensitive && !isCopied && item.contentType != "image" {
                    let preview = item.title != nil ? item.content : ""
                    if !preview.isEmpty {
                        Text(preview.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }

                // Metadata
                HStack(spacing: 6) {
                    Text(timeAgo(from: item.timestamp))

                    if let appName = item.appName {
                        Text("\u{00B7}")
                        Text(appName)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Spacer()

            // Favorite indicator
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(4)
            }
        }
        .modifier(ClipboardItemRowStyle(isSelected: isSelected, isHovering: isHovering))
        .draggable(item.content)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hover
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue(item.isFavorite ? "Favorite" : "")
        .accessibilityHint("Double click to copy. Use context menu for more actions.")
    }

    private var accessibilityDescription: String {
        let type = item.contentType == "image" ? "Image" : "Text"
        let content = item.isSensitive ? "Sensitive content" : String((item.title ?? item.content).prefix(60))
        let app = item.appName ?? "Unknown app"
        return "\(type) from \(app): \(content)"
    }

    private var richIconName: String {
        if item.isSensitive { return "lock.fill" }
        if isCode { return "chevron.left.forwardslash.chevron.right" }
        if isURL { return "link" }
        switch item.contentType {
        case "image": return "photo"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }

    private var richIconGradient: LinearGradient { item.iconGradient }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func timeAgo(from date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

struct GlassSearchBar: View {
    @Binding var searchText: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Ask your clipboard...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        // .padding(16) removed for toolbar usage
    }
}

// MARK: - Row Style Modifier
struct ClipboardItemRowStyle: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool
    
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(isSelected ? 0.15 : 0.04), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}
