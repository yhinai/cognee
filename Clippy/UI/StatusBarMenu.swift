import SwiftUI
import SwiftData

struct StatusBarMenu: View {
    @Query(sort: \Item.timestamp, order: .reverse, animation: .default)
    private var recentItems: [Item]

    @EnvironmentObject var container: AppDependencyContainer
    @State private var copiedItemId: PersistentIdentifier?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "paperclip")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Clipboard History")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
                Text("Recent")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 12)

            // Item List or Empty State
            if recentItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(recentItems.prefix(10).enumerated()), id: \.element.persistentModelID) { index, item in
                            StatusBarItemRow(
                                item: item,
                                shortcutNumber: index + 1,
                                isCopied: copiedItemId == item.persistentModelID
                            )
                            .onTapGesture {
                                copyItem(item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
                .padding(.horizontal, 12)

            // Footer
            HStack(spacing: 12) {
                Button(action: openMainWindow) {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11))
                        Text("Open Clippy")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .background(.regularMaterial)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "paperclip")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No clipboard history yet")
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Actions

    private func copyItem(_ item: Item) {
        // Set skip flag to prevent feedback loop
        container.clipboardMonitor.skipNextClipboardChange = true

        if item.contentType == "image", let imagePath = item.imagePath {
            ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
        } else {
            ClipboardService.shared.copyTextToClipboard(item.content)
        }

        // Show feedback
        withAnimation(.easeInOut(duration: 0.2)) {
            copiedItemId = item.persistentModelID
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                if copiedItemId == item.persistentModelID {
                    copiedItemId = nil
                }
            }
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title != "" || $0.contentViewController != nil }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Status Bar Item Row

struct StatusBarItemRow: View {
    let item: Item
    let shortcutNumber: Int
    let isCopied: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Content type icon
            ZStack {
                Circle()
                    .fill(iconGradient)
                    .frame(width: 28, height: 28)

                if isCopied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(isCopied ? .green : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 4) {
                    if let appName = item.appName {
                        Text(appName)
                    }
                    Text(timeAgo(from: item.timestamp))
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }

            Spacer()

            // Keyboard shortcut hint
            if shortcutNumber <= 10 {
                Text(shortcutNumber == 10 ? "0" : "\(shortcutNumber)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isSensitive ? "Sensitive item" : displayText), from \(item.appName ?? "unknown")")
        .accessibilityHint("Tap to copy this item to clipboard")
    }

    private var displayText: String {
        if isCopied {
            return "Copied!"
        }
        if item.isSensitive {
            return String(repeating: "\u{2022}", count: min(item.content.count, 20))
        }
        if item.contentType == "image" {
            return "[Image]"
        }
        let text = item.title ?? item.content
        return String(text.prefix(50)).replacingOccurrences(of: "\n", with: " ")
    }

    private var iconName: String { item.iconSystemName }

    private var iconGradient: LinearGradient {
        if isCopied {
            return LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return item.iconGradient
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func timeAgo(from date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
