import BrowserCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the file manager asks the window to do.
struct FileActions {
    /// Opens a file; the other files in its folder come along for paging.
    var open: (FileItem, [FileItem]) -> Void
    var share: ([URL]) -> Void
    var export: ([URL]) -> Void
    var saveToPhotos: ([URL]) -> Void
    var openPage: (URL) -> Void
    /// The page a downloaded file came from.
    var sourcePage: (URL) -> URL?
    var close: () -> Void
}

/// The file manager (Aloha-style): the app's folders in Files, with a Done button.
struct FilesView: View {
    @ObservedObject var files: FileStore
    let actions: FileActions
    let startFolder: URL?
    @State private var path: [URL] = []

    init(files: FileStore, actions: FileActions, startFolder: URL? = nil) {
        self.files = files
        self.actions = actions
        self.startFolder = startFolder
    }

    var body: some View {
        NavigationStack(path: $path) {
            FolderView(folder: files.root, files: files, actions: actions)
                .navigationDestination(for: URL.self) { folder in
                    FolderView(folder: folder, files: files, actions: actions)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: actions.close)
                            .accessibilityIdentifier("filesDoneButton")
                    }
                }
        }
        .onAppear {
            guard path.isEmpty, let startFolder, files.isSameOrInside(startFolder, files.root),
                  startFolder.standardizedFileURL != files.root.standardizedFileURL
            else { return }
            // Open the folders leading to the start folder.
            var folders: [URL] = []
            var folder = startFolder
            while folder.standardizedFileURL != files.root.standardizedFileURL, files.isSameOrInside(folder, files.root) {
                folders.insert(folder, at: 0)
                folder = folder.deletingLastPathComponent()
            }
            path = folders
        }
    }
}

/// One folder: list or grid, sorting, search, selection and every file action.
struct FolderView: View {
    let folder: URL
    @ObservedObject var files: FileStore
    let actions: FileActions

    @AppStorage("fileSort") private var sort: FileSort = .name
    @AppStorage("fileSortReversed") private var reversed = false
    @AppStorage("fileGrid") private var grid = false
    @State private var items: [FileItem] = []
    @State private var selection = Set<URL>()
    @State private var editMode: EditMode = .inactive
    @State private var searchText = ""
    @State private var searchResults: [FileItem] = []
    @State private var renaming: FileItem?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var moving: [URL]?
    @State private var copying: [URL]?
    @State private var importingFiles = false
    @State private var importingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingTrash = false
    @State private var info: FileItem?
    @State private var deleting: [URL]?
    @State private var errorMessage: String?
    @State private var storage: (used: Int64, available: Int64?)?
    @State private var dropTargeted = false
    @State private var passwordTarget: FileItem?
    @State private var archivePassword = ""

    private var isRoot: Bool {
        folder.standardizedFileURL == files.root.standardizedFileURL
    }

    private var title: String {
        isRoot ? "Files" : folder.lastPathComponent
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var shown: [FileItem] {
        sort.sorted(isSearching ? searchResults : items, entry: \.entry, reversed: reversed)
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search \(isRoot ? "Files" : folder.lastPathComponent)")
            .environment(\.editMode, $editMode)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { operationBanner }
            .onAppear(perform: reload)
            .onChange(of: files.revision) { _, _ in reload() }
            .task(id: searchText) { await search() }
            .onDrop(of: [.fileURL, .item], isTargeted: $dropTargeted, perform: importDropped)
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    run { try files.importFiles(urls, into: folder) }
                }
            }
            .photosPicker(isPresented: $importingPhotos, selection: $photoItems, maxSelectionCount: 50, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, picked in importPhotos(picked) }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let item = renaming {
                        run { try files.rename(item.url, to: newName) }
                    }
                    renaming = nil
                }
            }
            .alert("New Folder", isPresented: $creatingFolder) {
                TextField("Name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    run { try files.createFolder(named: folderName, in: folder) }
                }
            }
            .confirmationDialog(
                deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let urls = deleting {
                        run { try files.delete(urls) }
                        selection.removeAll()
                        editMode = .inactive
                    }
                    deleting = nil
                }
            } message: {
                Text(AppServices.shared.preferences.useTrash
                     ? "Deleted items stay in the Trash for 30 days."
                     : "This can't be undone.")
            }
            .alert("Password", isPresented: Binding(get: { passwordTarget != nil }, set: { if !$0 { passwordTarget = nil } })) {
                SecureField("Password", text: $archivePassword)
                Button("Cancel", role: .cancel) { passwordTarget = nil }
                Button("Extract") {
                    if let item = passwordTarget, let format = item.archiveFormat {
                        extract(item, format: format, password: archivePassword)
                    }
                    passwordTarget = nil
                }
            } message: {
                Text("“\(passwordTarget?.name ?? "")” is protected with a password.")
            }
            .alert("Couldn't Finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
                FolderPickerView(files: files, title: "Move", action: "Move Here", excluding: moving ?? []) { destination in
                    if let urls = moving {
                        run { try files.move(urls, to: destination) }
                    }
                    moving = nil
                    finishSelection()
                }
            }
            .sheet(isPresented: Binding(get: { copying != nil }, set: { if !$0 { copying = nil } })) {
                FolderPickerView(files: files, title: "Copy", action: "Copy Here", excluding: []) { destination in
                    if let urls = copying {
                        run { try files.copy(urls, to: destination) }
                    }
                    copying = nil
                    finishSelection()
                }
            }
            .sheet(isPresented: $showingTrash) {
                TrashView(files: files, trash: files.trash)
            }
            .sheet(item: $info) { item in
                FileInfoView(item: item, location: files.displayPath(of: item.url.deletingLastPathComponent()),
                             sourcePage: actions.sourcePage(item.url))
            }
    }

    private var deleteTitle: String {
        let count = deleting?.count ?? 0
        return count == 1 ? "Delete “\(deleting?.first?.lastPathComponent ?? "")”?" : "Delete \(count) Items?"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if grid && !isSearching {
            ScrollView {
                if isRoot { storageHeader.padding(.horizontal) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)], spacing: 18) {
                    ForEach(shown) { item in
                        tile(item)
                    }
                }
                .padding()
            }
            .overlay { emptyState }
        } else {
            List(selection: $selection) {
                if isRoot && !isSearching {
                    Section { } header: { storageHeader }
                }
                ForEach(shown) { item in
                    row(item)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if shown.isEmpty {
            if isSearching {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    "No Files", systemImage: "folder",
                    description: Text("Downloads and imported files appear here."))
            }
        }
    }

    @ViewBuilder
    private var storageHeader: some View {
        if let storage {
            let available = storage.available.map { " · \(DownloadFormatting.bytes($0)) available on this iPad" } ?? ""
            Label("Using \(DownloadFormatting.bytes(storage.used))\(available)", systemImage: "internaldrive")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var operationBanner: some View {
        if let operation = files.operation {
            HStack(spacing: 12) {
                if let fraction = operation.fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView()
                }
                Text(operation.title).font(.subheadline)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
        }
    }

    private func row(_ item: FileItem) -> some View {
        Group {
            if item.isDirectory && editMode == .inactive {
                NavigationLink(value: item.url) {
                    FileRow(item: item, showsLocation: isSearching ? location(of: item) : nil)
                }
            } else {
                FileRow(item: item, showsLocation: isSearching ? location(of: item) : nil)
                    .onTapGesture {
                        if editMode == .inactive {
                            open(item)
                        }
                    }
            }
        }
        .tag(item.url)
        .contextMenu { menu(for: item) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = [item.url] } label: { Label("Delete", systemImage: "trash") }
        }
        .draggable(item.url)
    }

    private func tile(_ item: FileItem) -> some View {
        let selected = selection.contains(item.url)
        return Group {
            if item.isDirectory && editMode == .inactive {
                NavigationLink(value: item.url) {
                    FileTile(item: item)
                }
                .buttonStyle(.plain)
            } else {
                FileTile(item: item, isSelected: selected)
                    .onTapGesture {
                        if editMode == .active {
                            if selected { selection.remove(item.url) } else { selection.insert(item.url) }
                        } else {
                            open(item)
                        }
                    }
            }
        }
        .contextMenu { menu(for: item) }
        .draggable(item.url)
    }

    private func location(of item: FileItem) -> String {
        files.displayPath(of: item.url.deletingLastPathComponent())
    }

    // MARK: Menus and toolbar

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        if !item.isDirectory {
            Button { open(item) } label: { Label("Open", systemImage: "doc.viewfinder") }
        }
        Button { actions.share([item.url]) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
        Button {
            newName = item.name
            renaming = item
        } label: { Label("Rename…", systemImage: "pencil") }
        Button { run { try files.duplicate(item.url) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { moving = [item.url] } label: { Label("Move…", systemImage: "folder") }
        Button { copying = [item.url] } label: { Label("Copy To…", systemImage: "doc.on.doc") }
        Divider()
        Button { compress([item.url]) } label: { Label("Compress", systemImage: "archivebox") }
        if let format = item.archiveFormat, ArchiveService.canExtract(format) {
            Button { extract(item, format: format) } label: { Label("Extract", systemImage: "archivebox.circle") }
        }
        if item.isImage || item.isMovie {
            Button { actions.saveToPhotos([item.url]) } label: { Label("Save to Photos", systemImage: "photo.badge.arrow.down") }
        }
        Button { actions.export([item.url]) } label: { Label("Save to Files…", systemImage: "folder.badge.plus") }
        if let page = actions.sourcePage(item.url) {
            Button { actions.openPage(page) } label: { Label("Open Source Page", systemImage: "safari") }
        }
        Button { info = item } label: { Label("Get Info", systemImage: "info.circle") }
        Divider()
        Button(role: .destructive) { deleting = [item.url] } label: { Label("Delete", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if editMode == .active {
                Button("Done") { finishSelection() }
                    .accessibilityIdentifier("filesSelectDoneButton")
            } else {
                Menu {
                    Button { editMode = .active } label: { Label("Select", systemImage: "checkmark.circle") }
                    Button {
                        folderName = ""
                        creatingFolder = true
                    } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { importingFiles = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
                    Button { importingPhotos = true } label: { Label("Import Photos and Videos", systemImage: "photo.on.rectangle") }
                    Divider()
                    Picker("Sort By", selection: $sort) {
                        ForEach(FileSort.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle(isOn: $reversed) { Label("Reverse Order", systemImage: "arrow.up.arrow.down") }
                    Picker("View", selection: $grid) {
                        Label("List", systemImage: "list.bullet").tag(false)
                        Label("Icons", systemImage: "square.grid.2x2").tag(true)
                    }
                    Divider()
                    Button { showingTrash = true } label: { Label("Trash", systemImage: "trash") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("filesMenuButton")
            }
        }
        if editMode == .active {
            ToolbarItemGroup(placement: .bottomBar) {
                let urls = Array(selection)
                Button { actions.share(urls) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .disabled(urls.isEmpty)
                Spacer()
                Button { moving = urls } label: { Label("Move", systemImage: "folder") }
                    .disabled(urls.isEmpty)
                Spacer()
                Button { copying = urls } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(urls.isEmpty)
                Spacer()
                Button { compress(urls) } label: { Label("Compress", systemImage: "archivebox") }
                    .disabled(urls.isEmpty)
                Spacer()
                Button(role: .destructive) { deleting = urls } label: { Label("Delete", systemImage: "trash") }
                    .disabled(urls.isEmpty)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        items = files.contents(of: folder)
        selection = selection.filter { url in items.contains { $0.url == url } }
        if isRoot {
            Task {
                storage = await FileStore.storage(of: files.root)
            }
        }
    }

    private func search() async {
        guard isSearching else {
            searchResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let urls = await FileStore.search(searchText, in: folder)
        guard !Task.isCancelled else { return }
        searchResults = urls.compactMap(FileItem.init(url:))
    }

    private func open(_ item: FileItem) {
        actions.open(item, shown.filter { !$0.isDirectory })
    }

    private func finishSelection() {
        selection.removeAll()
        editMode = .inactive
    }

    private func run(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let destination = FileNaming.uniqueURL(in: first.deletingLastPathComponent(), for: "\(name).zip")
        finishSelection()
        Task {
            do {
                try await files.perform("Compressing…") { progress in
                    try ArchiveService.zip(urls, to: destination, progress: progress)
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func extract(_ item: FileItem, format: ArchiveFormat, password: String? = nil) {
        let parent = item.url.deletingLastPathComponent()
        let destination = FileNaming.uniqueURL(in: parent, for: ArchivePaths.folderName(forArchive: item.name))
        Task {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try await files.perform("Extracting \(item.name)…") { progress in
                    try ArchiveService.extract(item.url, format: format, to: destination, password: password, progress: progress)
                }
            } catch ArchiveService.Failure.needsPassword {
                try? FileManager.default.removeItem(at: destination)
                archivePassword = ""
                passwordTarget = item
            } catch {
                try? FileManager.default.removeItem(at: destination)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPhotos(_ picked: [PhotosPickerItem]) {
        guard !picked.isEmpty else { return }
        photoItems = []
        Task {
            var urls: [URL] = []
            for item in picked {
                if let media = try? await item.loadTransferable(type: PickedMedia.self) {
                    urls.append(media.url)
                }
            }
            run { try files.importFiles(urls, into: folder) }
            for url in urls {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
    }

    /// Files dragged in from other apps or other windows.
    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        let target = folder
        for provider in providers {
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { return }
                // The file is only valid inside this callback; copy it first.
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let copy = temp.appendingPathComponent(url.lastPathComponent)
                guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
                Task { @MainActor in
                    _ = try? AppServices.shared.files.importFiles([copy], into: target)
                    try? FileManager.default.removeItem(at: temp)
                }
            }
        }
        return !providers.isEmpty
    }
}
