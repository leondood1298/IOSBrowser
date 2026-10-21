import BrowserCore
import SwiftUI

/// The Settings screen. Later milestones add Privacy, Search and Downloads sections.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                linksSection
                searchSection
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("settingsDoneButton")
                }
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            Picker("Appearance", selection: binding(\.theme)) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.name).tag(theme)
                }
            }
            Picker("Website Layout", selection: binding(\.defaultLayout)) {
                Text("Desktop").tag(SiteLayout.desktop)
                Text("Mobile").tag(SiteLayout.mobile)
            }
            Picker("Page Zoom", selection: binding(\.defaultZoom)) {
                ForEach(ZoomLevels.steps, id: \.self) { step in
                    Text(ZoomLevels.percentText(step)).tag(step)
                }
            }
            Picker("User Agent", selection: binding(\.defaultUserAgent)) {
                ForEach(UserAgent.allCases) { agent in
                    Text(agent.name).tag(agent)
                }
            }
            if preferences.defaultUserAgent == .custom {
                TextField("Custom user agent", text: binding(\.customUserAgent), axis: .vertical)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var linksSection: some View {
        Section {
            Toggle("Ask Before Opening Apps", isOn: binding(\.askBeforeOpeningApps))
            Toggle("Let Links Open Apps", isOn: binding(\.allowLinksToOpenApps))
        } header: {
            Text("Links")
        } footer: {
            Text("When links can't open apps, links to sites that have an app stay in the browser, like in Firefox Focus.")
        }
    }

    private var searchSection: some View {
        Section("Search") {
            Picker("Search Engine", selection: binding(\.searchEngine)) {
                ForEach(SearchEngine.builtIn) { engine in
                    Text(engine.name).tag(engine)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Diagnostics.versionDescription)
            NavigationLink("Diagnostics") {
                DiagnosticsView()
            }
            NavigationLink("Third-Party Notices") {
                ScrollView {
                    Text(Self.notices)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Third-Party Notices")
            }
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { preferences[keyPath: keyPath] = $0 })
    }

    private static let notices = """
        Firefox Focus for iOS (Mozilla Public License 2.0) — parts of tracking protection, URL \
        autocomplete and search suggestions are adapted from github.com/mozilla-mobile/firefox-ios.

        Full notices are in THIRD_PARTY_NOTICES.md in the project repository.
        """
}
