import os
import Foundation

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.clippy.app"

    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let vector = Logger(subsystem: subsystem, category: "vector")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let services = Logger(subsystem: subsystem, category: "services")
    static let network = Logger(subsystem: subsystem, category: "network")
}
