import Foundation

/// The top-level folders of the file manager. Creating them at launch also makes the app's
/// Documents directory appear in the Files app, which hides it while it is empty.
enum AppFolders {
    static let defaultFolderNames = ["Downloads", "Videos", "Music", "Pictures", "Documents"]

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Deletes saved tabs, history, bookmarks and settings (not downloaded files).
    static func eraseSavedState() {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["Sessions", "Library"] {
            try? fileManager.removeItem(at: support.appendingPathComponent(name))
        }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }

    static func ensureDefaultFolders() {
        let fileManager = FileManager.default
        for name in defaultFolderNames {
            let folder = documentsDirectory.appendingPathComponent(name, isDirectory: true)
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}
