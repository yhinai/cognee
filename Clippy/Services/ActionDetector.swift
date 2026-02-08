import Foundation
import AppKit

enum ClipboardAction: Identifiable, Hashable {
    case openURL(URL)
    case openMaps(String)
    case createEvent(Date)
    case callNumber(String)
    case emailTo(String)
    
    var id: String {
        switch self {
        case .openURL(let url): return "url_\(url.absoluteString)"
        case .openMaps(let address): return "maps_\(address)"
        case .createEvent(let date): return "event_\(date.timeIntervalSinceReferenceDate)"
        case .callNumber(let number): return "call_\(number)"
        case .emailTo(let email): return "email_\(email)"
        }
    }
    
    var iconName: String {
        switch self {
        case .openURL: return "safari"
        case .openMaps: return "map"
        case .createEvent: return "calendar.badge.plus"
        case .callNumber: return "phone.fill"
        case .emailTo: return "envelope.fill"
        }
    }
    
    var label: String {
        switch self {
        case .openURL: return "Open Link"
        case .openMaps: return "Open Maps"
        case .createEvent: return "Add to Calendar"
        case .callNumber: return "Call"
        case .emailTo: return "Email"
        }
    }
    
    @MainActor
    func perform() {
        switch self {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            
        case .openMaps(let address):
            // Apple Maps URL scheme
            if let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
            
        case .createEvent:
            // Opening Calendar app generally
            // Deep linking to create an event is harder without EventKit usage directly,
            // but opening Calendar is a safe "Action".
            // A more advanced version works with EventKit.
            if let appUrl = URL(string: "ical://") {
                NSWorkspace.shared.open(appUrl)
            }
            
        case .callNumber(let number):
            if let url = URL(string: "tel://\(number.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())") {
                NSWorkspace.shared.open(url)
            }
            
        case .emailTo(let email):
            if let url = URL(string: "mailto:\(email)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

class ActionDetector {
    static let shared = ActionDetector()
    private let detector: NSDataDetector?
    
    private init() {
        // We only care about specific types
        let types: NSTextCheckingResult.CheckingType = [.link, .date, .address, .phoneNumber]
        detector = try? NSDataDetector(types: types.rawValue)
    }
    
    func detectActions(in text: String) -> [ClipboardAction] {
        guard let detector = detector, !text.isEmpty else { return [] }
        
        // Limit text length for performance
        let searchRange = NSRange(location: 0, length: min(text.utf16.count, 2000))
        var actions: [ClipboardAction] = []
        
        detector.enumerateMatches(in: text, options: [], range: searchRange) { match, _, stop in
            guard let match = match else { return }
            
            switch match.resultType {
            case .link:
                if let url = match.url {
                    // Valid URL check (sometimes detector finds weird things)
                    if url.scheme?.lowercased().hasPrefix("http") == true {
                        actions.append(.openURL(url))
                    } else if url.scheme?.lowercased() == "mailto" {
                        // handled by link usually but specialized logic below
                        // actions.append(.emailTo(url.absoluteString)) // Simplify
                        actions.append(.openURL(url))
                    }
                }
                
            case .date:
                if let date = match.date {
                    actions.append(.createEvent(date))
                }
                
            case .address:
                if match.components != nil, let range = Range(match.range, in: text) {
                    let addressString = String(text[range])
                    actions.append(.openMaps(addressString))
                }
                
            case .phoneNumber:
                if let number = match.phoneNumber {
                    actions.append(.callNumber(number))
                }
                
            default:
                break
            }
            
            // Limit to first 3 actionable items to avoid clutter
            if actions.count >= 3 {
                stop.pointee = true
            }
        }
        
        // Deduplicate while preserving order
        var seen = Set<ClipboardAction>()
        return actions.filter { seen.insert($0).inserted }
    }
}
