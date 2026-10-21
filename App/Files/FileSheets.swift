import BrowserCore
import SwiftUI

/// Picks a folder to move or copy items into.
struct FolderPickerView: View {
    @ObservedObject var files: FileStore
    let title: String
    let action: String
    /// Items being moved: they (and folders inside them) can't be the destination.
    let excluding: [URL]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    init(files: FileStore, title: String, action: String, excluding: [URL], onPick: @escaping (URL) -> Void) {
        self.files = files
        self.title = title
        self.action = action
        self.excluding = excluding
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            FolderPickerLevel(folder: files.root, files: files, action: action, excluding: excluding, onPick: onPick)
                .navigationDestination(for: URL.self) { folder in
                    FolderPickerLevel(folder: folder, files: files, action: action, excluding: excluding, onPick: onPick)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

private struct FolderPickerLevel: View {
    let folder: URL
    @ObservedObject var files: FileStore
    let action: String
    let excluding: [URL]
    let onPick: (URL) -> Void

    private var subfolders: [FileItem] {
        files.contents(of: folder)
            .filter { item in item.isDirectory && !excluding.contains { files.isSameOrInside(item.url, $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(subfolders) { item in
            NavigationLink(value: item.url) {
                Label(item.name, systemImage: "folder")
            }
        }
        .overlay {
            if subfolders.isEmpty {
                ContentUnavailableView("No Folders Inside", systemImage: "folder")
            }
        }
        .navigationTitle(files.displayPath(of: folder))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action) { onPick(folder) }
                    .accessibilityIdentifier("pickFolderButton")
            }
        }
    }
}

/// Deleted files, with how long each is kept, and Restore.
struct TrashView: View {
    @ObservedObject var files: FileStore
    @ObservedObject var trash: TrashStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingEmpty = false
    @State private var errorMessage: String?

    init(files: FileStore, trash: TrashStore) {
        self.files = files
        self.trash = trash
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(trash.records) { record in
                    HStack(spacing: 14) {
                        Image(systemName: record.isDirectory
                              ? "folder.fill" : FileCategory.of(fileName: record.name).symbolName)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name).lineLimit(2)
                            let days = record.daysLeft()
                            Text("\(DownloadFormatting.bytes(record.size)) · \(days == 0 ? "Deleted today for good" : "\(days) days left")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button { restore(record) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { trash.deleteForever(record) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { restore(record) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { trash.deleteForever(record) } label: {
                            Label("Delete Now", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if trash.records.isEmpty {
                    ContentUnavailableView(
                        "Trash Is Empty", systemImage: "trash",
                        description: Text("Deleted files stay here for 30 days."))
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", role: .destructive) { confirmingEmpty = true }
                        .disabled(trash.records.isEmpty)
                }
            }
            .confirmationDialog("Empty Trash?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
                Button("Delete \(trash.records.count) Items", role: .destructive) { trash.empty() }
            } message: {
                Text("This can't be undone.")
            }
            .alert("Couldn't Restore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func restore(_ record: TrashRecord) {
        do {
            try files.restore(record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Details about a file or folder.
struct FileInfoView: View {
    let item: FileItem
    let location: String
    let sourcePage: URL?
    @Environment(\.dismiss) private var dismiss

    init(item: FileItem, location: String, sourcePage: URL?) {
        self.item = item
        self.location = location
        self.sourcePage = sourcePage
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        FileThumbnail(item: item, size: 120)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Kind", value: item.kind)
                    if item.isDirectory {
                        LabeledContent("Items", value: "\(item.childCount ?? 0)")
                    } else {
                        LabeledContent("Size", value: DownloadFormatting.bytes(item.size))
                    }
                    LabeledContent("Where", value: location)
                    if let created = item.created {
                        LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Modified", value: item.modified.formatted(date: .abbreviated, time: .shortened))
                }
                if let sourcePage {
                    Section("Downloaded From") {
                        Text(sourcePage.absoluteString)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
