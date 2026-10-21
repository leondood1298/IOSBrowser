import BackgroundTasks
import BrowserCore
import UIKit

/// Shows running downloads in a system Live Activity and keeps the app running in the background
/// until they finish, using iPadOS 26's continued processing task. It has to be started from the
/// foreground in response to a tap (Download, Resume, Retry). If the person stops it from the
/// Live Activity, or the system ends it, the downloads pause and can be resumed later.
final class DownloadActivity {
    static let identifierPrefix = "io.github.leondood1298.browser.downloads."

    /// Pauses every running download (with resume data) when the task ends early.
    var onExpire: (() -> Void)?
    private var task: BGContinuedProcessingTask?
    /// Submitted but not started yet.
    private var pending = false
    /// The downloads shown in this activity, so finished ones still count toward its progress.
    private var included: Set<UUID> = []

    var isRunning: Bool {
        task != nil || pending
    }

    /// A download started from a tap. Starts the activity if none is running.
    func downloadStarted(_ id: UUID, title: String) {
        if !isRunning {
            included.removeAll()
        }
        included.insert(id)
        guard !isRunning, UIApplication.shared.applicationState == .active else { return }
        let identifier = Self.identifierPrefix + UUID().uuidString
        // Each identifier may be registered once; registering the wildcard itself isn't allowed.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                self?.started(task)
            }
        }
        guard registered else {
            Log.event("Downloads Live Activity: identifier not permitted", category: "downloads")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting…")
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            pending = true
            // A queued request may never start (too many running); don't wait for it forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.pending, self.task == nil else { return }
                self.pending = false
            }
        } catch {
            Log.event("Downloads Live Activity couldn't start: \(error.localizedDescription)", category: "downloads")
        }
    }

    private func started(_ task: BGTask) {
        pending = false
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        self.task = task
        task.expirationHandler = { [weak self] in
            MainActor.assumeIsolated {
                self?.expired()
            }
        }
        task.progress.totalUnitCount = 100
        Log.event("Downloads Live Activity started", category: "downloads")
    }

    /// Updates the progress and text, and ends the activity once nothing is downloading.
    func update(with items: [DownloadItem]) {
        guard let task else { return }
        let shown = items.filter { included.contains($0.id) }
        let downloading = shown.filter { $0.record.state == .running || $0.record.state == .queued }
        guard !downloading.isEmpty else {
            finish(success: shown.allSatisfy { $0.record.state == .finished })
            return
        }
        // Each download counts 100 units, so downloads of unknown size still move the bar.
        let completed = shown.reduce(Int64(0)) { sum, item in
            switch item.record.state {
            case .finished: return sum + 100
            case .running, .queued, .paused: return sum + Int64((item.record.fractionCompleted ?? 0) * 100)
            case .failed, .cancelled: return sum + 100
            }
        }
        task.progress.totalUnitCount = Int64(shown.count) * 100
        task.progress.completedUnitCount = min(completed, task.progress.totalUnitCount)
        let title = downloading.count == 1
            ? "Downloading \(downloading[0].record.fileName)"
            : "Downloading \(downloading.count) files"
        let received = downloading.reduce(Int64(0)) { $0 + $1.record.receivedBytes }
        let expected = downloading.compactMap(\.record.expectedBytes)
        let subtitle = expected.count == downloading.count
            ? DownloadFormatting.progress(received: received, expected: expected.reduce(0, +))
            : DownloadFormatting.bytes(received)
        task.updateTitle(title, subtitle: subtitle)
    }

    private func expired() {
        Log.event("Downloads Live Activity stopped early; pausing downloads", category: "downloads")
        onExpire?()
        finish(success: false)
    }

    private func finish(success: Bool) {
        task?.setTaskCompleted(success: success)
        task = nil
        included.removeAll()
    }
}
