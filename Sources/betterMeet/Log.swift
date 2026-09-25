import Foundation
import os

/// Diagnostics go to the unified log (Console.app, `log stream --predicate
/// 'subsystem == "com.flup-repo.betterMeet"'`) and, unchanged, to stderr,
/// which the LaunchAgent redirects to /tmp/betterMeet.err.log.
/// Messages carry state and paths only, never transcript text.
enum Log {
    private static let logger = Logger(subsystem: "com.flup-repo.betterMeet", category: "daemon")
    /// Truncate the LaunchAgent's stderr file at startup beyond this size.
    static let maximumErrorLogBytes = 5 * 1024 * 1024

    static func write(_ message: String) {
        logger.log("\(message.trimmingCharacters(in: .newlines), privacy: .public)")
        FileHandle.standardError.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
    }

    /// launchd opens the stderr file in append mode, so truncating it in place
    /// is safe and keeps it from growing across months of uptime.
    static func trimErrorLog(at path: String = "/tmp/betterMeet.err.log") {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > maximumErrorLogBytes else { return }
        truncate(path, 0)
    }
}
