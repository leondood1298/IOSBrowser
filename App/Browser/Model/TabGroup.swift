import BrowserCore
import Combine
import Foundation

/// An ordered set of tabs shown together in one window. Untitled groups belong to a window;
/// titled groups are named tab groups. Private groups are never saved.
final class TabGroup: ObservableObject, Identifiable {
    let id: UUID
    let isPrivate: Bool
    let created: Date
    @Published var title: String? { didSet { onChange?() } }
    @Published private(set) var tabs: [TabModel] = []
    @Published var selectedTabID: UUID? { didSet { onChange?() } }

    /// Called after any change that should be saved.
    var onChange: (() -> Void)?

    init(id: UUID = UUID(), isPrivate: Bool, title: String? = nil, created: Date = Date()) {
        self.id = id
        self.isPrivate = isPrivate
        self.title = title
        self.created = created
    }

    var selectedTab: TabModel? {
        tabs.first { $0.id == selectedTabID }
    }

    func index(of tab: TabModel) -> Int? {
        tabs.firstIndex { $0 === tab }
    }

    func insert(_ tab: TabModel, at index: Int? = nil) {
        let position = min(max(index ?? tabs.count, 0), tabs.count)
        tabs.insert(tab, at: position)
        onChange?()
    }

    /// Removes the tab and returns where it was.
    @discardableResult
    func remove(_ tab: TabModel) -> Int? {
        guard let index = index(of: tab) else { return nil }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = nil
        }
        onChange?()
        return index
    }

    func removeAll() {
        tabs.removeAll()
        selectedTabID = nil
        onChange?()
    }

    func move(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), destination >= 0, destination < tabs.count, source != destination else {
            return
        }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        onChange?()
    }

    func makeSnapshot() -> TabGroupSnapshot {
        TabGroupSnapshot(
            id: id, title: title, tabs: tabs.map { $0.makeSnapshot() }, selectedTabID: selectedTabID, created: created)
    }
}
