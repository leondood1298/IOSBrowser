import SwiftUI

/// Shown in a tab that has no page yet. M1b adds shortcuts and recent sites.
struct NewTabPageView: View {
    let isPrivate: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isPrivate ? "hand.raised.fill" : "globe")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.secondary)
            Text(isPrivate ? "Private Browsing" : "New Tab")
                .font(.title.weight(.semibold))
            if isPrivate {
                Text("Private tabs don't save history. Their cookies and site data are kept in memory only and erased when the app quits.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else {
                Text("Search or enter an address above.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newTabPage")
    }
}
