import SwiftUI
import SwiftData
import AppKit
import os
@main
struct ClippyApp: App {
    // MARK: - Model Container
    // SwiftData lightweight migration handles adding new optional/defaulted columns
    // (expiresAt: Date?, isSensitiveFlag: Bool = false) automatically.
    // For future breaking schema changes, adopt VersionedSchema + SchemaMigrationPlan.
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            // SwiftData's lightweight migration will add new optional/defaulted
            // columns without data loss.
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Migration failed — try once more before destroying data.
            // New optional fields (expiresAt, isSensitiveFlag) should migrate
            // automatically, but if the store is truly corrupted we need to recover.
            Logger.services.error("ModelContainer creation failed: \(error.localizedDescription, privacy: .public)")
            Logger.services.info("Attempting fresh ModelContainer (data will be reset)")

            // Delete the existing store file so we can start clean
            let storeURL = modelConfiguration.url
            let related = [
                storeURL,
                storeURL.appendingPathExtension("wal"),
                storeURL.appendingPathExtension("shm")
            ]
            for url in related {
                try? FileManager.default.removeItem(at: url)
            }
            UserDefaults.standard.set(true, forKey: "didResetDatabase")

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                // Last resort: use an in-memory store so the app at least launches
                Logger.services.error("Fresh ModelContainer also failed: \(error.localizedDescription, privacy: .public). Falling back to in-memory store.")
                let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                do {
                    return try ModelContainer(for: schema, configurations: [inMemoryConfig])
                } catch {
                    fatalError("Could not create even an in-memory ModelContainer: \(error)")
                }
            }
        }
    }()

    @StateObject private var container = AppDependencyContainer()
    @State private var urlCopyText: String?
    @State private var showURLCopyConfirmation: Bool = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(container)
                .fontDesign(.rounded)
                .onAppear {
                    container.inject(modelContext: sharedModelContainer.mainContext)
                }
                .onOpenURL { url in
                    handleURLScheme(url)
                }
                .alert("External Copy Request", isPresented: $showURLCopyConfirmation) {
                    Button("Allow") {
                        if let text = urlCopyText {
                            container.clipboardMonitor.skipNextClipboardChange = true
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        urlCopyText = nil
                    }
                    Button("Deny", role: .cancel) {
                        urlCopyText = nil
                    }
                } message: {
                    Text("An external app wants to copy text to your clipboard:\n\"\(String((urlCopyText ?? "").prefix(100)))\"")
                }
        }
        .defaultSize(width: 960, height: 640)
        .modelContainer(sharedModelContainer)

        MenuBarExtra("Clippy", systemImage: "paperclip") {
            StatusBarMenu()
                .environmentObject(container)
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - URL Scheme Handler

    private func handleURLScheme(_ url: URL) {
        guard url.scheme == "clippy" else { return }
        let host = url.host()

        switch host {
        case "search":
            // clippy://search?q=query
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let query = components.queryItems?.first(where: { $0.name == "q" })?.value {
                Logger.services.info("URL scheme: search for '\(query, privacy: .public)'")
                // Activate the app and post notification for search
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .clippyURLSearch, object: query)
            }

        case "copy":
            // clippy://copy?text=Hello
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let text = components.queryItems?.first(where: { $0.name == "text" })?.value {
                Logger.services.info("URL scheme: copy text requested")
                urlCopyText = text
                showURLCopyConfirmation = true
            }

        case "latest":
            // clippy://latest - copy most recent item
            Logger.services.info("URL scheme: copy latest")
            let context = sharedModelContainer.mainContext
            var descriptor = FetchDescriptor<Item>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            descriptor.fetchLimit = 1
            if let items = try? context.fetch(descriptor), let latest = items.first {
                if latest.isSensitive {
                    Logger.services.warning("URL scheme: skipping sensitive item for latest copy")
                } else {
                    container.clipboardMonitor.skipNextClipboardChange = true
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(latest.content, forType: .string)
                }
            }

        default:
            Logger.services.warning("Unknown URL scheme host: \(host ?? "nil", privacy: .public)")
        }
    }
}

// MARK: - URL Scheme Notifications

extension Notification.Name {
    static let clippyURLSearch = Notification.Name("clippyURLSearch")
}
