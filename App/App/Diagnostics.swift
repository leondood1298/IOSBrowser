import MetricKit
import OSLog
import UIKit

/// Collects crash and hang reports (MetricKit) and builds a shareable log file, since the app
/// runs without a debugger attached.
final class Diagnostics: NSObject {
    static let shared = Diagnostics()

    nonisolated static var reportsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        Log.event("Launched \(Self.versionDescription)")
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Browser \(version) (\(build)) on iPadOS \(UIDevice.current.systemVersion)"
    }

    /// Saved crash, hang and exception reports, newest first.
    func reportFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.reportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func deleteReports() {
        for file in reportFiles() {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Writes device details, this run's unified log and the persistent log file to a text file.
    func exportLog() async -> URL {
        let header = Self.versionDescription
        let model = UIDevice.current.model
        return await Task.detached(priority: .userInitiated) {
            var text = "\(header)\nDevice: \(model)\nExported: \(Date())\n\n== This run ==\n"
            text += Self.currentRunLog()
            text += "\n== Log file ==\n" + LogFile.shared.contents()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Browser-log.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }.value
    }

    nonisolated private static func currentRunLog() -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "(unavailable)\n" }
        let position = store.position(timeIntervalSinceLatestBoot: 0)
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return "(unavailable)\n" }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(entry.date) [\(entry.category)] \(entry.composedMessage)")
        }
        return lines.suffix(3000).joined(separator: "\n") + "\n"
    }
}

extension Diagnostics: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = Self.reportsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        for payload in payloads {
            let name = "report-\(formatter.string(from: payload.timeStampEnd)).json"
                .replacingOccurrences(of: ":", with: "-")
            try? payload.jsonRepresentation().write(to: directory.appendingPathComponent(name))
        }
        LogFile.shared.append("[app] Received \(payloads.count) diagnostic report(s)")
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}
}
