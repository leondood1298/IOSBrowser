import BrowserCore
import Combine
import Foundation

/// The search engines the user can pick: the built-in ones they haven't removed, plus their own.
/// The chosen engine is stored in Preferences by id.
final class SearchEngineStore: ObservableObject {
    nonisolated struct Saved: Codable, Sendable {
        var custom: [SearchEngine] = []
        var removedBuiltInIDs: [String] = []
    }

    nonisolated enum AddError: LocalizedError {
        case missingName
        case invalidTemplate
        case duplicateName

        var errorDescription: String? {
            switch self {
            case .missingName: return "Enter a name for the search engine."
            case .invalidTemplate: return "Enter a search URL that contains %s where the search terms go."
            case .duplicateName: return "A search engine with that name already exists."
            }
        }
    }

    @Published private(set) var saved: Saved
    private let file: JSONFileStore<Saved>
    private let preferences: Preferences

    init(preferences: Preferences, file: JSONFileStore<Saved> = LibraryFiles.store("search-engines.json")) {
        self.preferences = preferences
        self.file = file
        saved = file.load() ?? Saved()
    }

    var engines: [SearchEngine] {
        SearchEngine.builtIn.filter { !saved.removedBuiltInIDs.contains($0.id) } + saved.custom
    }

    var defaultEngine: SearchEngine {
        engines.first { $0.id == preferences.searchEngineID } ?? engines.first ?? .google
    }

    func select(_ engine: SearchEngine) {
        objectWillChange.send()
        preferences.searchEngineID = engine.id
    }

    func addEngine(name: String, template: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AddError.missingName }
        guard SearchEngine.isValidTemplate(trimmedTemplate) else { throw AddError.invalidTemplate }
        let allNames = (SearchEngine.builtIn + saved.custom).map { $0.name.lowercased() }
        guard !allNames.contains(trimmedName.lowercased()) else { throw AddError.duplicateName }
        let engine = SearchEngine(id: "custom-\(UUID().uuidString)", name: trimmedName, searchTemplate: trimmedTemplate)
        saved.custom.append(engine)
        save()
        // Like Firefox Focus, a newly added engine becomes the default.
        select(engine)
    }

    /// Removes an engine (built-in ones can be restored). The default engine can't be removed.
    func remove(_ engine: SearchEngine) {
        guard engine.id != defaultEngine.id else { return }
        if SearchEngine.builtIn.contains(where: { $0.id == engine.id }) {
            saved.removedBuiltInIDs.append(engine.id)
        } else {
            saved.custom.removeAll { $0.id == engine.id }
        }
        save()
    }

    func restoreDefaults() {
        saved.removedBuiltInIDs.removeAll()
        save()
    }

    var hasRemovedBuiltIns: Bool {
        !saved.removedBuiltInIDs.isEmpty
    }

    private func save() {
        LibraryFiles.write(saved, to: file)
    }
}
