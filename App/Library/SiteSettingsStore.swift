import BrowserCore
import Combine
import Foundation

/// Per-site zoom, layout and user agent choices.
final class SiteSettingsStore: ObservableObject {
    @Published private(set) var index: SiteSettingsIndex

    private let file: JSONFileStore<SiteSettingsIndex>

    init(file: JSONFileStore<SiteSettingsIndex> = LibraryFiles.store("site-settings.json")) {
        self.file = file
        index = file.load() ?? SiteSettingsIndex()
    }

    func settings(for url: URL?) -> SiteSettings {
        index.settings(for: url)
    }

    func update(_ url: URL?, _ change: (inout SiteSettings) -> Void) {
        index.update(url, change)
        LibraryFiles.write(index, to: file)
    }
}
