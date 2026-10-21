import BrowserCore
import Combine
import SwiftUI

/// Backs the "aA" popover: zoom, desktop or mobile layout, and user agent for the current site.
final class PageSettingsModel: ObservableObject {
    let tab: TabModel
    private let sites: SiteSettingsStore
    private let preferences: Preferences

    @Published private(set) var zoom: Double
    @Published private(set) var layout: SiteLayout
    @Published private(set) var userAgent: UserAgent?

    var onFind: (() -> Void)?

    init(tab: TabModel, services: AppServices) {
        self.tab = tab
        sites = services.siteSettings
        preferences = services.preferences
        let settings = services.siteSettings.settings(for: tab.url)
        zoom = settings.zoom ?? services.preferences.defaultZoom
        layout = settings.layout ?? services.preferences.defaultLayout
        userAgent = settings.userAgent
    }

    var host: String {
        URLDisplay.host(for: tab.url) ?? "This page"
    }

    var zoomText: String {
        ZoomLevels.percentText(zoom)
    }

    func zoomIn() { setZoom(ZoomLevels.next(after: zoom)) }
    func zoomOut() { setZoom(ZoomLevels.previous(before: zoom)) }
    func resetZoom() { setZoom(preferences.defaultZoom) }

    private func setZoom(_ value: Double) {
        zoom = value
        tab.setZoom(value, remember: true)
    }

    func toggleLayout() {
        layout = layout == .desktop ? .mobile : .desktop
        tab.setLayout(layout)
    }

    func setUserAgent(_ agent: UserAgent?) {
        userAgent = agent
        tab.setUserAgentOverride(agent)
    }
}

struct PageSettingsView: View {
    @ObservedObject var model: PageSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.host)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                Button(action: model.zoomOut) {
                    Image(systemName: "textformat.size.smaller").frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Zoom Out")
                .accessibilityIdentifier("zoomOutButton")
                Divider().frame(height: 28)
                Button(action: model.resetZoom) {
                    Text(model.zoomText).monospacedDigit().frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Actual Size, currently \(model.zoomText)")
                .accessibilityIdentifier("zoomResetButton")
                Divider().frame(height: 28)
                Button(action: model.zoomIn) {
                    Image(systemName: "textformat.size.larger").frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Zoom In")
                .accessibilityIdentifier("zoomInButton")
            }
            .font(.title3)
            Divider()
            row(model.layout == .desktop ? "Request Mobile Website" : "Request Desktop Website",
                systemImage: model.layout == .desktop ? "iphone" : "desktopcomputer",
                action: model.toggleLayout)
            Divider()
            Menu {
                Button("Use Default") { model.setUserAgent(nil) }
                ForEach(UserAgent.allCases.filter { $0 != .custom }) { agent in
                    Button(agent.name) { model.setUserAgent(agent) }
                }
            } label: {
                HStack {
                    Label("User Agent", systemImage: "person.text.rectangle")
                    Spacer()
                    Text(model.userAgent?.name ?? "Default").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            }
            Divider()
            row("Find on Page", systemImage: "doc.text.magnifyingglass") { model.onFind?() }
        }
        .frame(width: 320)
        .buttonStyle(.plain)
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
    }
}
