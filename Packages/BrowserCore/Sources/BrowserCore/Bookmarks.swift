import Foundation

/// A saved page.
public struct Bookmark: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var created: Date

    public init(id: UUID = UUID(), title: String, url: URL, created: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.created = created
    }
}

/// A site pinned to the New Tab page (Firefox Focus calls these shortcuts).
public struct Shortcut: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: URL

    public init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// Bookmarks and New Tab page shortcuts, saved together.
public struct BookmarkLibrary: Codable, Equatable, Sendable {
    public var bookmarks: [Bookmark]
    public var shortcuts: [Shortcut]

    public init(bookmarks: [Bookmark] = [], shortcuts: [Shortcut] = []) {
        self.bookmarks = bookmarks
        self.shortcuts = shortcuts
    }

    public func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { Self.same($0.url, url) }
    }

    public func hasShortcut(for url: URL) -> Bool {
        shortcuts.contains { Self.same($0.url, url) }
    }

    /// URLs match when they differ only by a trailing slash or fragment.
    public static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    static func normalized(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var text = (components?.string ?? url.absoluteString).lowercased()
        if text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}
