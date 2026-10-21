import BrowserCore
import Combine
import Foundation

/// Owns every normal (saved) tab group and writes them to disk. Each window shows one group;
/// private groups live in their window only and are never saved.
final class TabStore: ObservableObject {
    @Published private(set) var groups: [TabGroup] = []

    private let file: JSONFileStore<SessionSnapshot>
    private var saveTask: Task<Void, Never>?

    init(file: JSONFileStore<SessionSnapshot> = TabStore.defaultFile()) {
        self.file = file
        restore()
    }

    static func defaultFile() -> JSONFileStore<SessionSnapshot> {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONFileStore(url: support.appendingPathComponent("Sessions/session.json"))
    }

    func group(withID id: UUID) -> TabGroup? {
        groups.first { $0.id == id }
    }

    /// A new, empty normal group (a window's own group when `title` is nil).
    func makeGroup(title: String? = nil) -> TabGroup {
        let group = TabGroup(isPrivate: false, title: title)
        adopt(group)
        groups.append(group)
        scheduleSave()
        return group
    }

    func remove(_ group: TabGroup) {
        group.removeAll()
        groups.removeAll { $0 === group }
        scheduleSave()
    }

    /// Saves shortly after the last change, so bursts of navigation write once.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = SessionSnapshot(groups: groups.map { $0.makeSnapshot() })
        do {
            try file.save(snapshot)
        } catch {
            Log.event("Saving tabs failed: \(error.localizedDescription)", category: "tabs")
        }
    }

    private func restore() {
        guard let snapshot = file.load() else { return }
        groups = snapshot.groups.map { saved in
            let group = TabGroup(id: saved.id, isPrivate: false, title: saved.title, created: saved.created)
            for tab in saved.tabs {
                group.insert(TabModel(snapshot: tab))
            }
            group.selectedTabID = saved.selectedTabID ?? group.tabs.last?.id
            adopt(group)
            return group
        }
        Log.event("Restored \(groups.count) tab group(s)", category: "tabs")
    }

    private func adopt(_ group: TabGroup) {
        group.onChange = { [weak self] in self?.scheduleSave() }
    }
}
