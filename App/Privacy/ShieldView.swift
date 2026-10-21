import BrowserCore
import SwiftUI

/// The tracking protection popover shown from the shield in the address bar, like Firefox Focus's
/// shield panel: connection security, the protection switches, and what was blocked.
struct ShieldView: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var sites: SiteSettingsStore
    let favicons: FaviconStore
    /// Called after any switch changes, so the content blocker re-applies its lists.
    var onChange: () -> Void

    @State private var confirmingContent = false

    init(tab: TabModel, services: AppServices, onChange: @escaping () -> Void) {
        self.tab = tab
        preferences = services.preferences
        sites = services.siteSettings
        favicons = services.favicons
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Toggle(isOn: Binding(get: { preferences.trackingProtectionEnabled }, set: { value in
                preferences.trackingProtectionEnabled = value
                onChange()
            })) {
                Label("Enhanced Tracking Protection", systemImage: "shield.lefthalf.filled")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .accessibilityIdentifier("trackingProtectionToggle")
            if preferences.trackingProtectionEnabled {
                Divider()
                Toggle(isOn: Binding(get: { !siteDisabled }, set: { value in
                    sites.update(tab.url) { $0.trackingProtectionDisabled = value ? nil : true }
                    onChange()
                })) {
                    Text("Protection on This Site")
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .accessibilityIdentifier("siteProtectionToggle")
                Divider()
                ForEach(TrackerCategory.allCases) { category in
                    categoryRow(category)
                }
            }
            Divider()
            Text("\(preferences.lifetimeTrackersBlocked.formatted()) trackers blocked since \(preferences.installDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .frame(width: 340)
        .alert("Block Other Content Trackers?", isPresented: $confirmingContent) {
            Button("Cancel", role: .cancel) {}
            Button("Block") {
                preferences.setBlocking(.content, true)
                onChange()
            }
        } message: {
            Text("Blocking other content trackers may break some videos and web pages.")
        }
    }

    private var siteDisabled: Bool {
        sites.settings(for: tab.url).trackingProtectionDisabled == true
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let url = tab.url {
                SiteIcon(url: url, title: tab.title, favicons: favicons, size: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(URLDisplay.host(for: tab.url) ?? "This page").font(.headline).lineLimit(1)
                Label(tab.hasOnlySecureContent ? "Connection is secure" : "Connection is not secure",
                      systemImage: tab.hasOnlySecureContent ? "lock.fill" : "lock.open.fill")
                    .font(.caption)
                    .foregroundStyle(tab.hasOnlySecureContent ? Color.secondary : Color.orange)
            }
        }
        .padding(16)
    }

    private func categoryRow(_ category: TrackerCategory) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                Text(countText(tab.trackerCounts[category]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(category.name, isOn: Binding(get: { preferences.isBlocking(category) }, set: { value in
                if category == .content && value {
                    confirmingContent = true
                } else {
                    preferences.setBlocking(category, value)
                    onChange()
                }
            }))
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("category-\(category.rawValue)")
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? "1 blocked on this page" : "\(count) blocked on this page"
    }
}
