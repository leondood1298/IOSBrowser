import SwiftUI

/// Clear Browsing Data: choose a time range and what to remove from normal browsing.
struct ClearDataView: View {
    var onClear: (ClearDataRequest) -> Void
    var onCancel: () -> Void

    @State private var request = ClearDataRequest()

    init(onClear: @escaping (ClearDataRequest) -> Void, onCancel: @escaping () -> Void) {
        self.onClear = onClear
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Clear", selection: $request.range) {
                        ForEach(ClearDataRequest.Range.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                }
                Section {
                    Toggle("History", isOn: $request.history)
                    Toggle("Cookies and Website Data", isOn: $request.cookiesAndSiteData)
                    Toggle("Cached Images and Files", isOn: $request.cache)
                    Toggle("Recently Closed Tabs", isOn: $request.closedTabs)
                    Toggle("Download List", isOn: $request.downloadList)
                } footer: {
                    Text("Private tabs aren't affected; use Erase for those. Clearing cookies signs you out of websites.")
                }
                Section {
                    Button("Clear Browsing Data", role: .destructive) {
                        onClear(request)
                    }
                    .accessibilityIdentifier("confirmClearDataButton")
                    .disabled(request.isEmpty)
                }
            }
            .navigationTitle("Clear Browsing Data")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
