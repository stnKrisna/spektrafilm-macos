import Foundation

/// Severity levels for the shared application log. Higher rank = more severe,
/// and a configured minimum level suppresses anything ranked below it.
public enum LogLevel: String, Sendable, CaseIterable {
    case debug, info, warning, error

    public var levelRank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    /// Padded, right-aligned uppercase label so `[INFO ]`/`[ERROR]` line up.
    public var paddedLabel: String {
        let label = rawValue.uppercased()
        return label + String(repeating: " ", count: max(6 - label.count, 0))
    }
}

/// Shared application log. Safe to call from any actor: `emit` takes a lock so
/// lines from background renders do not interleave, and configuration is only
/// touched at startup.
public struct AppLog {
    /// Destination switch; when false no line is emitted at all (SPEKTRALOG=silent).
    public nonisolated(unsafe) static var enabled: Bool = true
    /// Messages ranked below this are dropped.
    public nonisolated(unsafe) static var minimumLevel: LogLevel = .debug
    /// Injectable writer.
    public nonisolated(unsafe) static var sink: (LogLevel, String, String) -> Void = AppLog.console
    /// Guards the mutable configuration and line emission.
    private static let lock = NSLock()


    @inline(__always) private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    /// Apply the SPEKTRALOG environment variable if present.
    /// Values: silent, debug, info, warning, error. Anything else logs a warning
    /// and leaves the current verbosity untouched.
    public static func configureFromEnvironment() {
        let manualLog = ProcessInfo.processInfo.environment["SPEKTRALOG"]
        withLock {
            guard let raw = manualLog else {
                let saved = minimumLevel
                emitUnlocked(.debug, "config", "Logging defaulting to \(saved) (set SPEKTRALOG to override)")
                return
            }
            let value = raw.lowercased()
            if value == "silent" {
                enabled = false
                return
            }
            guard value == "debug" || value == "info" || value == "warning" || value == "error" else {
                consoleUnlocked(.warning, "config", "Unknown SPEKTRALOG value '\(raw)'; keeping level \(minimumLevel)")
                return
            }
            minimumLevel = LogLevel(rawValue: value) ?? .info
            emitUnlocked(.debug, "config", "Logging level set to \(value)")
        }
    }

    public static func debug(_ category: String, _ message: String) { emit(.debug, category, message) }
    public static func info(_ category: String, _ message: String) { emit(.info, category, message) }
    public static func warning(_ category: String, _ message: String) { emit(.warning, category, message) }
    public static func error(_ category: String, _ message: String) { emit(.error, category, message) }

    private static func emit(_ level: LogLevel, _ category: String, _ message: String) {
        withLock { emitUnlocked(level, category, message) }
    }

    private static func emitUnlocked(_ level: LogLevel, _ category: String, _ message: String) {
        guard enabled && level.levelRank >= minimumLevel.levelRank else { return }
        consoleUnlocked(level, category, message)
    }

    /// Standard line format shared by any console-targeting writer:
    ///    2026-09-11T14:30:05.123Z [INFO ] [pipeline] Render complete
    public static func formatLine(_ level: LogLevel, _ category: String, _ message: String) -> String {
        "\(timestamp()) [\(level.paddedLabel)] [\(category)] \(message)"
    }

    /// Milliseconds elapsed since `start`. Helpful for cheap checkpoint timing.
    public static func msSince(_ start: ContinuousClock.Instant) -> Double {
        let e = ContinuousClock.now - start
        return Double(e.components.seconds) * 1000
            + Double(e.components.attoseconds) / 1_000_000_000_000_000
    }

    /// Render `ms` as a compact "123 ms" / "4.2 s" string for logging.
    public static func formatElapsed(_ ms: Double) -> String {
        if ms >= 1000 { return String(format: "%.2f s", ms / 1000) }
        return String(format: "%.0f ms", ms)
    }

    /// Default writer: info/debug to standard output, warnings/errors to standard error.
    public static func console(_ level: LogLevel, _ category: String, _ message: String) {
        let line = formatLine(level, category, message)
        let data = (line + "\n").data(using: .utf8)!
        if level == .warning || level == .error {
            FileHandle.standardError.write(data)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func consoleUnlocked(_ level: LogLevel, _ category: String, _ message: String) {
        let line = formatLine(level, category, message)
        let data = (line + "\n").data(using: .utf8)!
        if level == .warning || level == .error {
            FileHandle.standardError.write(data)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}