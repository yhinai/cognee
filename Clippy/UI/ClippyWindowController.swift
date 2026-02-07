import SwiftUI
import AppKit
import ApplicationServices
import ImageIO
import os

class ClippyWindowController: ObservableObject {
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var animationResetID = UUID()
    @Published var isVisible = false
    @Published var followTextInput = true // New property to enable/disable text input following
    @Published var currentState: ClippyAnimationState = .idle // Current animation state
    private var escapeKeyMonitor: Any? // Monitor for ESC key presses
    
    // MARK: - Position Persistence
    /// User's manually set position (saved to UserDefaults)
    private var savedPosition: NSPoint? {
        get {
            let x = UserDefaults.standard.double(forKey: "ClippyWindowX")
            let y = UserDefaults.standard.double(forKey: "ClippyWindowY")
            // Return nil if never saved (both will be 0)
            if x == 0 && y == 0 { return nil }
            return NSPoint(x: x, y: y)
        }
        set {
            if let point = newValue {
                UserDefaults.standard.set(point.x, forKey: "ClippyWindowX")
                UserDefaults.standard.set(point.y, forKey: "ClippyWindowY")
            }
        }
    }
    private var hasUserDraggedWindow = false
    
    /// Set the current animation state and update the display
    func setState(_ state: ClippyAnimationState, message: String? = nil) {
        DispatchQueue.main.async {
            self.currentState = state
            let displayMessage = message ?? state.defaultMessage
            let gifName = state.gifFileName
            
            Logger.ui.debug("Setting state to \(String(describing: state), privacy: .public) with GIF: \(gifName, privacy: .public)")
            
            // Create window if needed
            if self.window == nil {
                Logger.ui.debug("Creating new window")
                self.createWindow()
            }
            
            // Update the view content with new state - VERTICAL LAYOUT (Clippy on top, bubble below)
            self.hostingController?.rootView = AnyView(
                VStack(spacing: 8) {
                    // Clippy GIF (no background - transparent, allows drag-through)
                    ClippyGifPlayer(gifName: gifName)
                        .id(gifName)
                        .frame(width: 80, height: 60)
                        .allowsHitTesting(false) // Allow mouse events to pass through for window dragging
                    
                    // Message bubble (TRANSPARENT) - below Clippy
                    if !displayMessage.isEmpty || state == .thinking {
                        HStack(spacing: 8) {
                            if state == .thinking {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.primary)
                            }
                            
                            if !displayMessage.isEmpty {
                                Text(displayMessage)
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                    .foregroundColor(state == .error ? .red : .primary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        // Transparent background - no glass
                    }
                }
                .padding(8)
                .background(Color.clear)
                .contentShape(Rectangle()) // Makes entire area respond to drag
            )
            
            // Position window (use saved position if user has dragged, otherwise auto-position)
            if !self.isVisible {
                if let savedPos = self.savedPosition {
                    // Use the user's saved position
                    self.window?.setFrameOrigin(savedPos)
                    Logger.ui.debug("Restored saved position: \(savedPos.debugDescription, privacy: .public)")
                } else if self.followTextInput {
                    self.positionNearActiveTextInput()
                } else {
                    if let window = self.window {
                        self.positionWindowCentered(window)
                    }
                }
            }
            
            // Show the window
            self.window?.orderFrontRegardless()
            self.isVisible = true
            
            Logger.ui.debug("Window positioned and visible")
            
            // Start monitoring for ESC key when window is shown
            self.startEscapeKeyMonitoring()
            
            // Auto-hide after 'done' state (after 2 seconds)
            if state == .done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.hide()
                }
            }
        }
    }
    
    func hide() {
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.isVisible = false
            self.currentState = .idle // Reset to idle state
            
            // Stop monitoring ESC key when window is hidden
            self.stopEscapeKeyMonitoring()
            self.animationResetID = UUID()
        }
    }
    

    
    private func createWindow() {
        // Create the hosting controller
        // Initial view is empty/placeholder until show() is called
        self.hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        
        hostingController?.view.wantsLayer = true
        hostingController?.view.layer?.backgroundColor = NSColor.clear.cgColor
        
        // Create the window (sized for 124x93 Clippy animation)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 124, height: 93),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = window, let hostingController = hostingController else { return }
        
        // Configure window properties
        window.contentViewController = hostingController
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        // Ensure content view is transparent
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        
        // Position will be set when show() is called
        positionWindowCentered(window)
        
        // Window is ready but not shown yet
        window.alphaValue = 1.0
        
        // Observe window movements to save user's position
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        
        Logger.ui.debug("Window created and ready")
    }
    
    /// Called when the user drags the window
    @objc private func windowDidMove(_ notification: Notification) {
        guard let window = window else { return }
        savedPosition = window.frame.origin
        hasUserDraggedWindow = true
        Logger.ui.debug("User moved window to: \(window.frame.origin.debugDescription, privacy: .public)")
    }
    
    /// Reset to auto-positioning (clears saved position)
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "ClippyWindowX")
        UserDefaults.standard.removeObject(forKey: "ClippyWindowY")
        hasUserDraggedWindow = false
        if let window = window {
            positionWindowCentered(window)
        }
        Logger.ui.debug("Position reset to default")
    }
    
    // MARK: - Public Methods
    
    /// Toggle whether the clippy follows the active text input
    func setFollowTextInput(_ enabled: Bool) {
        followTextInput = enabled
        Logger.ui.info("Text input following: \(enabled ? "enabled" : "disabled", privacy: .public)")
    }
    
    /// Manually reposition the clippy near the current text input (if following is enabled)
    func repositionNearTextInput() {
        guard followTextInput else { return }
        positionNearActiveTextInput()
    }
    
    // MARK: - Text Input Positioning
    
    /// Position the clippy window near the currently active text input element
    private func positionNearActiveTextInput() {
        guard let window = window else { return }
        positionWindowCentered(window)
    }
    
    /// Get the frame (position and size) of the currently focused text input element
    private func getActiveTextInputFrame() -> NSRect? {
        guard AXIsProcessTrusted() else {
            Logger.ui.warning("Accessibility permission not granted")
            return nil
        }
        
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            Logger.ui.warning("No frontmost application")
            return nil
        }
        
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        
        guard result == AXError.success, let focusedElement = focusedElementRef else {
            Logger.ui.warning("Unable to locate focused UI element")
            return nil
        }
        
        let focusedUIElement = focusedElement as! AXUIElement

        // Check if the focused element is a text input (text field, text area, etc.)
        if !isTextInputElement(focusedUIElement) {
            Logger.ui.debug("Focused element is not a text input")
            return nil
        }
        
        // Try to get the exact caret position first
        if let caretFrame = getCaretPosition(focusedUIElement) {
            Logger.ui.debug("Found caret at: \(caretFrame.debugDescription, privacy: .public)")
            return caretFrame
        }
        
        // Fallback to text field bounds if caret position is not available
        guard let position = getElementPosition(focusedUIElement),
              let size = getElementSize(focusedUIElement) else {
            Logger.ui.warning("Unable to get text input position/size")
            return nil
        }
        
        let frame = NSRect(x: position.x, y: position.y, width: size.width, height: size.height)
        Logger.ui.debug("Found text input at: \(frame.debugDescription, privacy: .public) (fallback to field bounds)")
        return frame
    }
    
    /// Check if the given accessibility element is a text input
    private func isTextInputElement(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        
        guard roleResult == AXError.success, let role = roleRef as? String else {
            return false
        }
        
        // Common text input roles
        let textInputRoles = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole
        ]
        
        return textInputRoles.contains { $0 as String == role }
    }
    
    /// Get the position of an accessibility element
    private func getElementPosition(_ element: AXUIElement) -> NSPoint? {
        var positionRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        
        guard result == AXError.success, let ref = positionRef else {
            return nil
        }
        let positionValue = ref as! AXValue

        var point = NSPoint()
        let success = AXValueGetValue(positionValue, .cgPoint, &point)
        return success ? point : nil
    }
    
    /// Get the size of an accessibility element
    private func getElementSize(_ element: AXUIElement) -> NSSize? {
        var sizeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        
        guard result == AXError.success, let ref = sizeRef else {
            return nil
        }
        let sizeValue = ref as! AXValue

        var size = NSSize()
        let success = AXValueGetValue(sizeValue, .cgSize, &size)
        return success ? size : nil
    }
    
    /// Get the exact position of the text caret/cursor
    private func getCaretPosition(_ element: AXUIElement) -> NSRect? {
        // First, get the selected text range (which indicates the caret position)
        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)
        
        guard rangeResult == AXError.success, let selectedRangeValue = selectedRangeRef else {
            Logger.ui.warning("Unable to get selected text range")
            return nil
        }
        
        // Get the bounds for the selected range (caret position)
        var caretBoundsRef: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeValue,
            &caretBoundsRef
        )
        
        guard boundsResult == AXError.success, let ref = caretBoundsRef else {
            Logger.ui.warning("Unable to get caret bounds")
            return nil
        }
        let caretBoundsValue = ref as! AXValue

        var caretBounds = CGRect()
        let success = AXValueGetValue(caretBoundsValue, .cgRect, &caretBounds)
        
        if success {
            // Convert CGRect to NSRect and return
            return NSRect(x: caretBounds.origin.x, y: caretBounds.origin.y, width: max(caretBounds.width, 2), height: caretBounds.height)
        } else {
            Logger.ui.warning("Failed to extract caret bounds from AXValue")
            return nil
        }
    }
    
    /// Position the clippy window in the top-right area of the screen, away from the notch
    private func positionWindowCentered(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        
        let windowSize = window.frame.size
        let screenFrame = screen.visibleFrame // Use visible frame to avoid menu bar and dock
        
        // Position in top-right area with some padding from the edges
        let padding: CGFloat = 20
        let x = screenFrame.maxX - windowSize.width - padding
        let y = screenFrame.maxY - windowSize.height - padding
        
        let newOrigin = NSPoint(x: x, y: y)
        window.setFrameOrigin(newOrigin)
        
        Logger.ui.debug("Positioned clippy in top-right at: \(newOrigin.debugDescription, privacy: .public)")
    }
    
    // MARK: - ESC Key Monitoring
    
    /// Start monitoring for ESC key presses to dismiss the clippy
    private func startEscapeKeyMonitoring() {
        // Stop any existing monitor first
        stopEscapeKeyMonitoring()
        
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Check if ESC key was pressed (keyCode 53)
            if event.keyCode == 53 {
                Logger.ui.debug("ESC key pressed - hiding clippy")
                self?.hide()
            }
        }
        
        Logger.ui.debug("Started ESC key monitoring")
    }
    
    /// Stop monitoring for ESC key presses
    private func stopEscapeKeyMonitoring() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
            Logger.ui.debug("Stopped ESC key monitoring")
        }

        // Reset animation when dismissing the clippy so it restarts next time it's shown
        animationResetID = UUID()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopEscapeKeyMonitoring()
        window?.close()
    }
}

// MARK: - Clippy GIF Player

/// Custom NSImageView that ignores mouse events (allows window dragging)
class DraggableImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil // Ignore all mouse events - pass through to window
    }
}

struct ClippyGifPlayer: NSViewRepresentable {
    let gifName: String
    
    func makeNSView(context: Context) -> DraggableImageView {
        let imageView = DraggableImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        return imageView
    }
    
    func updateNSView(_ nsView: DraggableImageView, context: Context) {
        if let url = Bundle.main.url(forResource: gifName, withExtension: "gif") {
            if let image = NSImage(contentsOf: url) {
                nsView.image = image
                nsView.animates = true
            }
        } else if let url = Bundle.main.url(forResource: "ClippyGifs/\(gifName)", withExtension: "gif") {
            if let image = NSImage(contentsOf: url) {
                nsView.image = image
                nsView.animates = true
            }
        }
    }
}
