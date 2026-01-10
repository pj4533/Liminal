import Foundation
import OSLog

/// Centralized logging system for Liminal
/// Usage: LMLog.audio.info("Message")
public enum LMLog {
    private static let subsystem = "com.saygoodnight.Liminal"

    // Loggers for each category
    public static let general = Logger(subsystem: subsystem, category: "General")
    public static let audio = Logger(subsystem: subsystem, category: "Audio")
    public static let visual = Logger(subsystem: subsystem, category: "Visual")
    public static let state = Logger(subsystem: subsystem, category: "State")
    public static let ui = Logger(subsystem: subsystem, category: "UI")
    public static let gemini = Logger(subsystem: subsystem, category: "Gemini")
}
