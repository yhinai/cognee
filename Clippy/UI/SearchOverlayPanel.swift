import AppKit
import SwiftUI
import SwiftData
import os

// MARK: - NSPanel Subclass

class SearchOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }
}

// MARK: - Search Overlay Controller

@MainActor
class SearchOverlayController: ObservableObject {
    private var panel: SearchOverlayPanel?
    private var clickMonitor: Any?
    @Published var isVisible = false

    func toggle(modelContainer: ModelContainer, container: AppDependencyContainer) {
        if isVisible {
            hide()
        } else {
            show(modelContainer: modelContainer, container: container)
        }
    }

    func show(modelContainer: ModelContainer, container: AppDependencyContainer) {
        guard !isVisible else { return }

        let panelSize = NSSize(width: 680, height: 420)
        let panel = SearchOverlayPanel(contentRect: NSRect(origin: .zero, size: panelSize))
        self.panel = panel

        let overlayView = SearchOverlayView(
            onDismiss: { [weak self] in self?.hide() },
            onPaste: { [weak self] item in self?.pasteItem(item, container: container) }
        )
        .environmentObject(container)
        .modelContainer(modelContainer)

        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        centerOnActiveScreen(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        isVisible = true
        installClickMonitor()

        Logger.ui.info("Search overlay shown")
    }

    func hide() {
        guard let panel = panel, isVisible else { return }

        removeClickMonitor()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.panel = nil
            self?.isVisible = false
            Logger.ui.info("Search overlay hidden")
        })
    }

    private func centerOnActiveScreen(_ panel: SearchOverlayPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY - panelSize.height / 2 + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func pasteItem(_ item: Item, container: AppDependencyContainer) {
        // 1. Prevent clipboard feedback loop
        container.clipboardMonitor.skipNextClipboardChange = true

        // 2. Copy to clipboard
        if item.contentType == "image", let imagePath = item.imagePath {
            ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
        } else {
            ClipboardService.shared.copyTextToClipboard(item.content)
        }

        // 3. Dismiss overlay
        hide()

        // 4. Simulate Cmd+V paste after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.simulatePaste()
        }

        Logger.ui.info("Pasting item from search overlay")
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
        }
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
        }
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async {
                    self.hide()
                }
            }
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    deinit {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
