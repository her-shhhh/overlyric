import os

/// Unified-log loggers. Read with:
/// `log show --predicate 'subsystem == "com.harsh.overlyric"' --last 5m --style compact`
enum Log {
    static let subsystem = "com.harsh.overlyric"
    static let player = Logger(subsystem: subsystem, category: "player")
    static let lyrics = Logger(subsystem: subsystem, category: "lyrics")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
