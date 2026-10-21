import BrowserCore
import SwiftUI

/// What the Downloads list asks the window to do.
struct DownloadActions {
    var openFile: (DownloadItem) -> Void
    var share: (DownloadItem) -> Void
    var showInFiles: (DownloadItem) -> Void
    var openPage: (URL) -> Void
    /// The window to present "Download from URL" confirmation from.
    var presenter: () -> UIViewController?
    var isPrivate: () -> Bool
}

/// The Downloads screen: running, failed and finished downloads, like Aloha's.
struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    let actions: DownloadActions

    @State private var renaming: DownloadItem?
    @State private var newName = ""
    @State private var addingURL = false

    init(manager: DownloadManager, actions: DownloadActions) {
        self.manager = manager
        self.actions = actions
    }

    var body: some View {
        let active = manager.items.filter { $0.record.state.isActive }
        let failed = manager.items.filter { $0.record.state == .failed || $0.record.state == .cancelled }
        let finished = manager.items.filter { $0.record.state == .finished }
        List {
            if manager.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads", systemImage: "arrow.down.circle",
                    description: Text("Files you download appear here."))
                    .listRowBackground(Color.clear)
            }
            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active) { item in row(item) }
                }
            }
            if !failed.isEmpty {
                Section("Didn't Finish") {
                    ForEach(failed) { item in row(item) }
                }
            }
            if !finished.isEmpty {
                Section("Downloaded") {
                    ForEach(finished) { item in row(item) }
                }
            }
        }
        .accessibilityIdentifier("downloadsList")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingURL = true
                } label: {
                    Label("Download from URL", systemImage: "plus")
                }
                .accessibilityIdentifier("downloadFromURLButton")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Clear") { manager.clearInactive() }
                    .disabled(finished.isEmpty && failed.isEmpty)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let item = renaming {
                    try? manager.rename(item, to: newName)
                }
                renaming = nil
            }
        }
        .sheet(isPresented: $addingURL) {
            DownloadFromURLView { url in
                addingURL = false
                manager.download(url, isPrivate: actions.isPrivate(), presenter: actions.presenter())
            }
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        DownloadRow(item: item, manager: manager, actions: actions)
            .contextMenu { menu(for: item) }
            .swipeActions {
                Button(role: .destructive) {
                    manager.remove(item)
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
            }
    }

    @ViewBuilder
    private func menu(for item: DownloadItem) -> some View {
        let record = item.record
        if record.state == .finished {
            Button { actions.openFile(item) } label: { Label("Open", systemImage: "doc.viewfinder") }
            Button { actions.share(item) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            Button { actions.showInFiles(item) } label: { Label("Show in Files", systemImage: "folder") }
            Button {
                newName = record.fileName
                renaming = item
            } label: { Label("Rename…", systemImage: "pencil") }
        }
        if let page = record.pageURL {
            Button { actions.openPage(page) } label: { Label("Open Source Page", systemImage: "safari") }
        }
        if let source = record.sourceURL, source.scheme?.hasPrefix("http") == true {
            Button { UIPasteboard.general.url = source } label: { Label("Copy Download Link", systemImage: "link") }
        }
        Button { manager.remove(item) } label: { Label("Remove from List", systemImage: "xmark") }
        if record.state == .finished {
            Button(role: .destructive) { manager.deleteFile(item) } label: { Label("Delete File", systemImage: "trash") }
        }
    }
}

/// One download: icon, name, progress or state, and its buttons.
struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let manager: DownloadManager
    let actions: DownloadActions

    var body: some View {
        let record = item.record
        HStack(spacing: 14) {
            Image(systemName: item.category.symbolName)
                .font(.title2)
                .foregroundStyle(record.state == .failed ? Color.secondary : Color.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if record.state == .running || (record.state == .paused && record.fractionCompleted != nil) {
                    if let fraction = record.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(item.statusText)
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                if record.state == .failed || record.state == .cancelled {
                    HStack(spacing: 16) {
                        if record.canRetry {
                            Button("Retry") { manager.retry(item) }
                        }
                        if record.linkExpired, let page = record.pageURL {
                            Button("Open Source Page") { actions.openPage(page) }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 8)
            controls(for: record)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if record.state == .finished {
                actions.openFile(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download-\(record.fileName)")
    }

    @ViewBuilder
    private func controls(for record: DownloadRecord) -> some View {
        HStack(spacing: 14) {
            switch record.state {
            case .running, .queued:
                Button { manager.pause(item) } label: {
                    Image(systemName: "pause.circle").font(.title2)
                }
                .accessibilityLabel("Pause")
                Button { manager.cancel(item) } label: {
                    Image(systemName: "xmark.circle").font(.title2)
                }
                .accessibilityLabel("Cancel")
            case .paused:
                Button { manager.resume(item) } label: {
                    Image(systemName: "play.circle").font(.title2)
                }
                .accessibilityLabel("Resume")
                Button { manager.cancel(item) } label: {
                    Image(systemName: "xmark.circle").font(.title2)
                }
                .accessibilityLabel("Cancel")
            case .finished, .failed, .cancelled:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
    }
}

/// "Download from URL": an address field filled from the clipboard when it holds a link.
struct DownloadFromURLView: View {
    let onDownload: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    init(onDownload: @escaping (URL) -> Void) {
        self.onDownload = onDownload
    }

    private var url: URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") && url.host != nil || scheme == "data"
        else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/file.zip", text: $address, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("downloadURLField")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first {
                            address = first
                        }
                    }
                } footer: {
                    Text("Paste the address of a file to download it.")
                }
            }
            .navigationTitle("Download from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        if let url { onDownload(url) }
                    }
                    .disabled(url == nil)
                    .accessibilityIdentifier("startURLDownloadButton")
                }
            }
            .onAppear {
                // Fill in a copied link (iOS may ask once whether the app can paste).
                guard address.isEmpty, UIPasteboard.general.hasURLs,
                      let copied = UIPasteboard.general.url,
                      ["http", "https"].contains(copied.scheme?.lowercased() ?? "")
                else { return }
                address = copied.absoluteString
            }
        }
    }
}
