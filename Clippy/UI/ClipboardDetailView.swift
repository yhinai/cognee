import SwiftUI
import SwiftData

struct ClipboardDetailView: View {
    @Bindable var item: Item
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var container: AppDependencyContainer

    // UI State
    @State private var showCopiedFeedback: Bool = false
    @State private var isHoveringBar: Bool = false
    @State private var transformResult: String?
    @State private var showTransformCopied: Bool = false
    
    var body: some View {
        ZStack {
            // 1. Main Content Scroll
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    
                    // Header Section (Title & Meta)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(item.title ?? item.content)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(.top, 48) // Visual clearance for Toolbar (since ignoresSafeArea is on)
                        
                        HStack(spacing: 8) {
                            if let appName = item.appName {
                                Label(appName, systemImage: "app.fill")
                            }
                            Text("•")
                            Text(item.timestamp, format: .dateTime.day().month().hour().minute())
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                    // Divider (Subtle)
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                        .frame(height: 1)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)

                    // Content Area
                    VStack(alignment: .leading, spacing: 0) {
                        if item.contentType == "image", let imagePath = item.imagePath {
                            // Image Card
                            AsyncImageLoader(imagePath: imagePath)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(.white.opacity(0.1), lineWidth: 1)
                                )
                        } else {
                            // Text Display (Clean & Readable)
                            Text(item.content)
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .lineSpacing(6)
                                .foregroundColor(.primary.opacity(0.85))
                                .kerning(0.2) // Slight letter spacing for readability
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 24)

                    // Tags Section
                    if !item.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TAGS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.8))
                                .tracking(1)

                            FlowLayout(spacing: 8) {
                                ForEach(item.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.05))
                                        .foregroundColor(.secondary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.top, 24)
                        .padding(.horizontal, 24)
                    }

                    // Transforms Section
                    if item.contentType != "image" {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("TRANSFORMS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.8))
                                .tracking(1)

                            ForEach(TransformCategory.allCases, id: \.rawValue) { category in
                                let categoryTransforms = TransformRegistry.shared.transforms(for: category)
                                if !categoryTransforms.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(category.rawValue)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.secondary)

                                        FlowLayout(spacing: 6) {
                                            ForEach(categoryTransforms) { transform in
                                                Button {
                                                    transformResult = transform.transform(item.content)
                                                } label: {
                                                    Label(transform.name, systemImage: transform.icon)
                                                        .font(.system(size: 11, weight: .medium))
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 5)
                                                        .background(Color.primary.opacity(0.05))
                                                        .foregroundColor(.primary.opacity(0.7))
                                                        .clipShape(Capsule())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }

                            // Transform Result
                            if let result = transformResult {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Result")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Button {
                                            container.clipboardMonitor.skipNextClipboardChange = true
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(result, forType: .string)
                                            showTransformCopied = true
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                showTransformCopied = false
                                            }
                                        } label: {
                                            Label(showTransformCopied ? "Copied" : "Copy", systemImage: showTransformCopied ? "checkmark" : "doc.on.doc")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(showTransformCopied ? .green : .secondary)
                                    }

                                    Text(result)
                                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                                        .lineSpacing(4)
                                        .foregroundColor(.primary.opacity(0.85))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(Color.primary.opacity(0.03))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 24)
                        .padding(.horizontal, 24)
                    }

                    Spacer().frame(height: 72) // Clearance for floating bar
                }
            }
            
            // 2. Floating Action Capsule (Bottom Right)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 0) {
                        // Favorite
                        ActionButton(
                            icon: item.isFavorite ? "heart.fill" : "heart",
                            color: item.isFavorite ? .red : .primary,
                            action: { withAnimation(.snappy) { item.isFavorite.toggle() } }
                        )
                        .accessibilityLabel(item.isFavorite ? "Remove from favorites" : "Add to favorites")

                        Divider().frame(height: 16).padding(.horizontal, 8)

                        // Copy
                        ActionButton(
                            icon: showCopiedFeedback ? "checkmark" : "doc.on.doc",
                            color: showCopiedFeedback ? .green : .primary,
                            action: copyContentWithFeedback
                        )
                        .id("copy_btn")
                        .accessibilityLabel(showCopiedFeedback ? "Copied" : "Copy to clipboard")

                        Divider().frame(height: 16).padding(.horizontal, 8)

                        // Delete
                        ActionButton(
                            icon: "trash",
                            color: .secondary,
                            hoverColor: .red,
                            action: deleteItem
                        )
                        .accessibilityLabel("Delete item")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial) // Frosted glass pill
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .scaleEffect(isHoveringBar ? 1.02 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHoveringBar)
                    .onHover { isHoveringBar = $0 }
                    .padding(20)
                }
            }
        }
        .background(Color.clear) // Ensure transparency
        .ignoresSafeArea()
    }
    
    // MARK: - Actions
    
    private func copyContentWithFeedback() {
        container.clipboardMonitor.skipNextClipboardChange = true

        if item.contentType == "image", let imagePath = item.imagePath {
            ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
        } else {
            ClipboardService.shared.copyTextToClipboard(item.content)
        }
        
        withAnimation(.spring(duration: 0.3)) {
            showCopiedFeedback = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopiedFeedback = false }
        }
    }
    
    private func deleteItem() {
        guard let repository = container.repository else { return }
        Task { try? await repository.deleteItem(item) }
    }
}

// MARK: - Helper Components

/// A minimalist icon button for the floating bar
struct ActionButton: View {
    let icon: String
    var color: Color = .primary
    var hoverColor: Color? = nil
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isHovering ? (hoverColor ?? color) : color)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Legacy Helpers

struct AsyncImageLoader: View {
    let imagePath: String
    @State private var loadedImage: NSImage?
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView()
                    .frame(height: 200)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .frame(height: 200)
            }
        }
        .onAppear {
            loadImageAsync()
        }
    }
    
    private func loadImageAsync() {
        Task.detached(priority: .userInitiated) {
            let image = ClipboardService.shared.loadImage(from: imagePath)
            await MainActor.run {
                self.loadedImage = image
                self.isLoading = false
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize
        var positions: [CGPoint]
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var positions: [CGPoint] = []
            var size: CGSize = .zero
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let subviewSize = subview.sizeThatFits(.unspecified)
                
                if currentX + subviewSize.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: currentX, y: currentY))
                currentX += subviewSize.width + spacing
                lineHeight = max(lineHeight, subviewSize.height)
                size.width = max(size.width, currentX - spacing)
                size.height = currentY + lineHeight
            }
            
            self.size = size
            self.positions = positions
        }
    }
}
