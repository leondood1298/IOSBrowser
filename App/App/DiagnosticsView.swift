import SwiftUI

/// Version info, log export and crash reports, for troubleshooting on the device.
struct DiagnosticsView: View {
    @State private var exportedLog: URL?
    @State private var isExporting = false
    @State private var reports: [URL] = Diagnostics.shared.reportFiles()

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Version", value: Diagnostics.versionDescription)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
            }
            Section {
                if let exportedLog {
                    ShareLink(item: exportedLog) {
                        Label("Share Log", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task {
                            isExporting = true
                            exportedLog = await Diagnostics.shared.exportLog()
                            isExporting = false
                        }
                    } label: {
                        Label(isExporting ? "Preparing Log…" : "Prepare Log", systemImage: "doc.text")
                    }
                    .disabled(isExporting)
                }
            } header: {
                Text("Log")
            } footer: {
                Text("Includes this run's log and the saved log from earlier runs.")
            }
            Section("Crash and Hang Reports") {
                if reports.isEmpty {
                    Text("No reports").foregroundStyle(.secondary)
                } else {
                    ForEach(reports, id: \.self) { report in
                        ShareLink(item: report) {
                            Label(report.deletingPathExtension().lastPathComponent, systemImage: "exclamationmark.triangle")
                        }
                    }
                    Button("Delete All Reports", role: .destructive) {
                        Diagnostics.shared.deleteReports()
                        reports = Diagnostics.shared.reportFiles()
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
