import Foundation
import AppKit
import Carbon
import os

@MainActor
class HotkeyManager: ObservableObject {
    @Published var isListening = false
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onVisionTrigger: (() -> Void)?
    private var onTextCaptureTrigger: (() -> Void)?
    private var onVoiceCaptureTrigger: (() -> Void)?
    private var onUndoTrigger: (() -> Void)?
    private var isUndoAvailable: (() -> Bool)?
    private var onSearchOverlayTrigger: (() -> Void)?

    func startListening(
        onVisionTrigger: @escaping () -> Void,
        onTextCaptureTrigger: @escaping () -> Void,
        onVoiceCaptureTrigger: @escaping () -> Void,
        onUndoTrigger: (() -> Void)? = nil,
        isUndoAvailable: (() -> Bool)? = nil,
        onSearchOverlayTrigger: (() -> Void)? = nil
    ) {
        self.onVisionTrigger = onVisionTrigger
        self.onTextCaptureTrigger = onTextCaptureTrigger
        self.onVoiceCaptureTrigger = onVoiceCaptureTrigger
        self.onUndoTrigger = onUndoTrigger
        self.isUndoAvailable = isUndoAvailable
        self.onSearchOverlayTrigger = onSearchOverlayTrigger
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                
                // Check for Cmd+Shift+V (search overlay trigger)
                let flags = event.flags
                let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                if flags.contains(.maskCommand) && flags.contains(.maskShift) && keycode == 9 { // 9 = V
                    Logger.services.info("Cmd+Shift+V detected")
                    DispatchQueue.main.async {
                        manager.onSearchOverlayTrigger?()
                    }
                    return nil // Consume event
                }

                // Check for Option+X (text capture trigger)
                if event.flags.contains(.maskAlternate) && event.getIntegerValueField(.keyboardEventKeycode) == 7 { // 7 = X
                    Logger.services.info("Option+X detected")
                    DispatchQueue.main.async {
                        manager.onTextCaptureTrigger?()
                    }
                    return nil // Consume event
                }
                
                // Check for Option+Space (voice capture trigger)
                if event.flags.contains(.maskAlternate) && event.getIntegerValueField(.keyboardEventKeycode) == 49 { // 49 = Space
                    Logger.services.info("Option+Space detected")
                    DispatchQueue.main.async {
                        manager.onVoiceCaptureTrigger?()
                    }
                    return nil // Consume event
                }
                
                // Check for Option+V (vision parsing)
                if event.flags.contains(.maskAlternate) && event.getIntegerValueField(.keyboardEventKeycode) == 9 { // 9 = V
                    Logger.services.info("Option+V detected")
                    DispatchQueue.main.async {
                        manager.onVisionTrigger?()
                    }
                    return nil // Consume event
                }

                // Check for Cmd+Z (undo last replacement)
                if event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventKeycode) == 6 { // 6 = Z
                    if let isAvailable = manager.isUndoAvailable, isAvailable() {
                        Logger.services.info("Cmd+Z detected - triggering undo")
                        DispatchQueue.main.async {
                            manager.onUndoTrigger?()
                        }
                        return nil // Consume event
                    }
                    // Pass through normally so native Cmd+Z still works
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.services.error("Failed to create event tap. Check Accessibility permissions.")
            return
        }
        
        self.eventTap = eventTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isListening = true
    }
    
    func stopListening() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        isListening = false
    }
}


