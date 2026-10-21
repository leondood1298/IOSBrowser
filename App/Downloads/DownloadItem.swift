import BrowserCore
import Combine
import Foundation

/// One row in the Downloads list: the saved record plus the live speed while it runs.
final class DownloadItem: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var record: DownloadRecord
    @Published private(set) var bytesPerSecond: Double?
    /// Called when the state changes, so the list can move the row to another section.
    var onStateChange: (() -> Void)?
    private var rate = TransferRate()

    init(record: DownloadRecord) {
        id = record.id
        self.record = record
    }

    func update(_ change: (inout DownloadRecord) -> Void) {
        var copy = record
        change(&copy)
        guard copy != record else { return }
        let stateChanged = copy.state != record.state
        record = copy
        if stateChanged {
            onStateChange?()
        }
    }

    /// Moves to `state` when that's allowed from the current one (see `DownloadState.canMove`),
    /// applying `change` too. Returns whether it moved.
    @discardableResult
    func move(to state: DownloadState, change: (inout DownloadRecord) -> Void = { _ in }) -> Bool {
        guard record.state.canMove(to: state) else { return false }
        if state != .running {
            rate.reset()
            bytesPerSecond = nil
        }
        update { record in
            record.state = state
            change(&record)
        }
        return true
    }

    /// A progress reading from the running download.
    func progress(received: Int64, expected: Int64?, at time: TimeInterval) {
        rate.record(totalBytes: received, at: time)
        bytesPerSecond = rate.bytesPerSecond
        update { record in
            record.receivedBytes = received
            if let expected, expected > 0 {
                record.expectedBytes = expected
            }
        }
    }

    var fileURL: URL {
        AppFolders.documentsDirectory
            .appendingPathComponent(record.folder, isDirectory: true)
            .appendingPathComponent(record.fileName)
    }

    var category: FileCategory {
        FileCategory.of(fileName: record.fileName, mimeType: record.mimeType)
    }

    /// The line under the name: progress, speed and time left while running, otherwise the state.
    var statusText: String {
        let progress = DownloadFormatting.progress(received: record.receivedBytes, expected: record.expectedBytes)
        switch record.state {
        case .queued:
            return "Waiting…"
        case .running:
            var parts = [progress]
            if let speed = bytesPerSecond, speed > 0 {
                parts.append(DownloadFormatting.speed(speed))
                if let left = rate.secondsRemaining(expectedBytes: record.expectedBytes) {
                    parts.append(DownloadFormatting.timeLeft(left))
                }
            }
            return parts.joined(separator: " · ")
        case .paused:
            return ["Paused", progress, record.failureReason].compactMap { $0 }.joined(separator: " · ")
        case .finished:
            let size = record.expectedBytes ?? record.receivedBytes
            let date = (record.finished ?? record.created).formatted(date: .abbreviated, time: .shortened)
            return "\(DownloadFormatting.bytes(size)) · \(date)"
        case .failed:
            return record.failureReason ?? "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

extension FileCategory {
    nonisolated var symbolName: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }
}
