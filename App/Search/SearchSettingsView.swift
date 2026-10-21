import BrowserCore
import SwiftUI

/// Settings › Search: the engine list, search suggestions and URL autocomplete.
struct SearchSettingsView: View {
    @ObservedObject var engines: SearchEngineStore
    @ObservedObject var preferences: Preferences

    @State private var addingEngine = false

    init(engines: SearchEngineStore, preferences: Preferences) {
        self.engines = engines
        self.preferences = preferences
    }

    var body: some View {
        Form {
            Section {
                ForEach(engines.engines) { engine in
                    Button {
                        engines.select(engine)
                    } label: {
                        HStack {
                            Text(engine.name).foregroundStyle(.primary)
                            Spacer()
                            if engine.id == engines.defaultEngine.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .swipeActions {
                        if engine.id != engines.defaultEngine.id {
                            Button("Remove", role: .destructive) { engines.remove(engine) }
                        }
                    }
                }
                Button("Add Search Engine…") { addingEngine = true }
                if engines.hasRemovedBuiltIns {
                    Button("Restore Default Search Engines") { engines.restoreDefaults() }
                }
            } header: {
                Text("Search Engine")
            } footer: {
                Text("Swipe left on an engine to remove it. The one you're using can't be removed.")
            }

            Section {
                Toggle("Search Suggestions", isOn: Binding(get: { preferences.searchSuggestionsEnabled }, set: { value in
                    preferences.searchSuggestionsEnabled = value
                    preferences.searchSuggestionsPrompted = true
                }))
            } footer: {
                Text("As you type, what you type is sent to your search engine to get suggestions.")
            }

            Section("URL Autocomplete") {
                Toggle("Top Sites", isOn: Binding(get: { preferences.autocompleteTopSites }, set: { preferences.autocompleteTopSites = $0 }))
                Toggle("My Sites", isOn: Binding(get: { preferences.autocompleteCustomSites }, set: { preferences.autocompleteCustomSites = $0 }))
                NavigationLink("Manage Sites") {
                    CustomSitesView(preferences: preferences)
                }
            }
        }
        .navigationTitle("Search")
        .sheet(isPresented: $addingEngine) {
            AddSearchEngineView(engines: engines)
        }
    }
}

/// Adds a custom engine from a name and a URL with `%s` for the search terms.
struct AddSearchEngineView: View {
    @ObservedObject var engines: SearchEngineStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""
    @State private var errorMessage: String?

    init(engines: SearchEngineStore) {
        self.engines = engines
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("https://example.com/search?q=%s", text: $template, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text(errorMessage ?? "Search for something on the site, copy the results address and replace your search terms with %s.")
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Add Search Engine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try engines.addEngine(name: name, template: template)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

/// The user's own sites for URL autocomplete: add, delete and reorder.
struct CustomSitesView: View {
    @ObservedObject var preferences: Preferences
    @State private var newSite = ""
    @State private var invalid = false

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("example.com", text: $newSite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                    Button("Add", action: add)
                }
            } footer: {
                if invalid {
                    Text("Enter a site such as example.com.").foregroundStyle(.red)
                }
            }
            Section {
                ForEach(preferences.customAutocompleteDomains, id: \.self) { domain in
                    Text(domain)
                }
                .onDelete { offsets in
                    var domains = preferences.customAutocompleteDomains
                    domains.remove(atOffsets: offsets)
                    preferences.customAutocompleteDomains = domains
                }
                .onMove { source, destination in
                    var domains = preferences.customAutocompleteDomains
                    domains.move(fromOffsets: source, toOffset: destination)
                    preferences.customAutocompleteDomains = domains
                }
            }
        }
        .navigationTitle("Manage Sites")
        .toolbar { EditButton() }
    }

    private func add() {
        guard let domain = DomainCompletion.normalizedDomain(newSite) else {
            invalid = true
            return
        }
        invalid = false
        if !preferences.customAutocompleteDomains.contains(domain) {
            preferences.customAutocompleteDomains.append(domain)
        }
        newSite = ""
    }
}
