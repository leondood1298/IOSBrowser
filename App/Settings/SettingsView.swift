import BrowserCore
import SwiftUI

/// The Settings screen. Later milestones add Privacy, Search and Downloads sections.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var sites: SiteSettingsStore
    var onClearData: () -> Void
    var onDone: () -> Void

    @State private var confirmingContent = false

    init(preferences: Preferences, sites: SiteSettingsStore, onClearData: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.preferences = preferences
        self.sites = sites
        self.onClearData = onClearData
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                privacySection
                securitySection
                linksSection
                searchSection
                aboutSection
            }
            .alert("Block Other Content Trackers?", isPresented: $confirmingContent) {
                Button("Cancel", role: .cancel) {}
                Button("Block") {
                    preferences.setBlocking(.content, true)
                    ContentBlocker.shared.settingsChanged()
                }
            } message: {
                Text("Blocking other content trackers may break some videos and web pages.")
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

    private var privacySection: some View {
        Section {
            Toggle("Enhanced Tracking Protection", isOn: Binding(get: { preferences.trackingProtectionEnabled }, set: { value in
                preferences.trackingProtectionEnabled = value
                ContentBlocker.shared.settingsChanged()
            }))
            if preferences.trackingProtectionEnabled {
                ForEach(TrackerCategory.allCases) { category in
                    Toggle(category.name, isOn: Binding(get: { preferences.isBlocking(category) }, set: { value in
                        if category == .content && value {
                            confirmingContent = true
                        } else {
                            preferences.setBlocking(category, value)
                            ContentBlocker.shared.settingsChanged()
                        }
                    }))
                    .padding(.leading, 12)
                }
            }
            Toggle("Block Web Fonts", isOn: Binding(get: { preferences.blockWebFonts }, set: { value in
                preferences.blockWebFonts = value
                ContentBlocker.shared.settingsChanged()
            }))
            NavigationLink("Sites Without Protection") {
                ExceptionListView(sites: sites)
            }
            Button("Clear Browsing Data…", action: onClearData)
        } header: {
            Text("Privacy")
        } footer: {
            Text("\(preferences.lifetimeTrackersBlocked.formatted()) trackers blocked since \(preferences.installDate.formatted(date: .abbreviated, time: .omitted)).")
        }
    }

    private var securitySection: some View {
        Section {
            Picker("Lock with Face ID", selection: binding(\.appLock)) {
                ForEach(AppLockMode.allCases) { mode in
                    Text(mode.name).tag(mode)
                }
            }
            Toggle("Block JavaScript", isOn: binding(\.blockJavaScript))
            Toggle("Block Pop-ups", isOn: binding(\.blockPopups))
            Toggle("Upgrade Connections to HTTPS", isOn: binding(\.upgradeToHTTPS))
            Toggle("Fraudulent Website Warning", isOn: binding(\.fraudWarnings))
        } header: {
            Text("Security")
        } footer: {
            Text("Pop-up, HTTPS and fraud settings apply to tabs opened after the change.")
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
            NavigationLink {
                SearchSettingsView(engines: AppServices.shared.searchEngines, preferences: preferences)
            } label: {
                LabeledContent("Search", value: AppServices.shared.searchEngines.defaultEngine.name)
            }
            .accessibilityIdentifier("searchSettingsLink")
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

/// Sites where tracking protection is switched off, with swipe to turn it back on.
struct ExceptionListView: View {
    @ObservedObject var sites: SiteSettingsStore

    var body: some View {
        let domains = sites.index.sites.filter { $0.value.trackingProtectionDisabled == true }.map(\.key).sorted()
        List {
            if domains.isEmpty {
                Text("Tracking protection is on for every site. Turn it off for a site from the shield in the address bar.")
                    .foregroundStyle(.secondary)
            }
            ForEach(domains, id: \.self) { domain in
                Text(domain)
                    .swipeActions {
                        Button("Protect") {
                            sites.update(URL(string: "https://\(domain)")) { $0.trackingProtectionDisabled = nil }
                            ContentBlocker.shared.settingsChanged()
                        }
                        .tint(.blue)
                    }
            }
        }
        .navigationTitle("Sites Without Protection")
    }
}
