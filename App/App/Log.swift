import Foundation
import OSLog

/// App-wide loggers. `Log.event` also appends to a small log file so Diagnostics can export
/// messages from earlier runs (OSLogStore only returns the current process).
nonisolated enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.leondood1298.browser"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let web = Logger(subsystem: subsystem, category: "web")
    static let tabs = Logger(subsystem: subsystem, category: "tabs")

    /// Logs to the unified log and the persistent log file.
    static func event(_ message: String, category: String = "app") {
        Logger(subsystem: subsystem, category: category).notice("\(message, privacy: .public)")
        LogFile.shared.append("[\(category)] \(message)")
    }
}

/// A capped text log in Library/Caches/Logs that survives relaunches and crashes.
nonisolated final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    let url: URL
    private let queue = DispatchQueue(label: "LogFile", qos: .utility)
    private let maxBytes = 1_000_000
    private let formatter = ISO8601DateFormatter()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = caches.appendingPathComponent("Logs/app.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    var previousURL: URL {
        url.deletingPathExtension().appendingPathExtension("previous.log")
    }

    func append(_ line: String) {
        let stamp = formatter.string(from: Date())
        queue.async { [url, maxBytes] in
            let data = Data("\(stamp) \(line)\n".utf8)
            let fileManager = FileManager.default
            if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
                try? fileManager.removeItem(at: self.previousURL)
                try? fileManager.moveItem(at: url, to: self.previousURL)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// The log contents, oldest first, including the rotated file.
    func contents() -> String {
        queue.sync {
            let previous = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return previous + current
        }
    }
}
