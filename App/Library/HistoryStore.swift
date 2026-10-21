import BrowserCore
import Combine
import Foundation

/// History for normal tabs, saved in the background a few seconds after changes.
final class HistoryStore: ObservableObject {
    @Published private(set) var index: HistoryIndex

    private let file: JSONFileStore<HistoryIndex>
    private var saveTask: Task<Void, Never>?

    init(file: JSONFileStore<HistoryIndex> = LibraryFiles.store("history.json")) {
        self.file = file
        index = file.load() ?? HistoryIndex()
    }

    func recordVisit(to url: URL, title: String) {
        index.recordVisit(to: url, title: title)
        scheduleSave()
    }

    func updateTitle(_ title: String, for url: URL) {
        index.updateTitle(title, for: url)
        scheduleSave()
    }

    func remove(_ url: URL) {
        index.remove(url)
        scheduleSave()
    }

    /// Clears visits from `date` onwards, or everything when `date` is nil.
    func clear(since date: Date?) {
        index.removeVisits(since: date)
        saveNow()
    }

    func saveNow() {
        saveTask?.cancel()
        LibraryFiles.write(index, to: file)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}

/// Where the library files live, and a helper that writes them off the main thread.
enum LibraryFiles {
    static func store<Value: Codable>(_ name: String) -> JSONFileStore<Value> {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONFileStore(url: support.appendingPathComponent("Library").appendingPathComponent(name))
    }

    static func write<Value: Codable & Sendable>(_ value: Value, to file: JSONFileStore<Value>) {
        Task.detached(priority: .utility) {
            do {
                try file.save(value)
            } catch {
                LogFile.shared.append("[library] Saving \(file.url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }
}
