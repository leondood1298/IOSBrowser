import Foundation

/// A saved tab: enough to show it in the tab strip and restore its back/forward history.
public struct TabSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var url: URL?
    public var title: String
    /// `WKWebView.interactionState`, an opaque blob holding the back/forward list.
    public var interactionState: Data?
    public var lastActive: Date

    public init(id: UUID, url: URL?, title: String, interactionState: Data?, lastActive: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.interactionState = interactionState
        self.lastActive = lastActive
    }
}

/// A saved tab group. Untitled groups belong to a single window; titled ones are named tab groups.
public struct TabGroupSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String?
    public var tabs: [TabSnapshot]
    public var selectedTabID: UUID?
    public var created: Date

    public init(id: UUID, title: String?, tabs: [TabSnapshot], selectedTabID: UUID?, created: Date) {
        self.id = id
        self.title = title
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.created = created
    }
}

/// Everything saved between launches for normal (non-private) browsing.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var groups: [TabGroupSnapshot]

    public init(version: Int = 1, groups: [TabGroupSnapshot]) {
        self.version = version
        self.groups = groups
    }
}
