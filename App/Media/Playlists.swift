import BrowserCore
import Combine
import SwiftUI

/// A named list of songs and videos, by path under Documents.
nonisolated struct Playlist: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var paths: [String] = []
}

/// The user's playlists (Aloha's "add to playlist").
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist]
    private let file: JSONFileStore<[Playlist]>
    private let root: URL

    init(root: URL = AppFolders.documentsDirectory, file: JSONFileStore<[Playlist]> = LibraryFiles.store("playlists.json")) {
        self.root = root
        self.file = file
        playlists = file.load() ?? []
    }

    @discardableResult
    func create(named name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? "Playlist" : trimmed)
        playlists.append(playlist)
        save()
        return playlist
    }

    func add(_ urls: [URL], to id: UUID, files: FileStore) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let paths = urls.map { files.relativePath(of: $0) }
        playlists[index].paths.append(contentsOf: paths.filter { !playlists[index].paths.contains($0) })
        save()
    }

    func remove(at offsets: IndexSet, from id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].paths.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int, in id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].paths.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        save()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// The playlist's files that still exist.
    func urls(of playlist: Playlist) -> [URL] {
        playlist.paths
            .map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() {
        LibraryFiles.write(playlists, to: file)
    }
}

/// Lists playlists; tap one to see and play it.
struct PlaylistsView: View {
    @ObservedObject var playlists: PlaylistStore
    @ObservedObject var audio: AudioPlayback
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var newName = ""

    init(playlists: PlaylistStore, audio: AudioPlayback) {
        self.playlists = playlists
        self.audio = audio
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlistID: playlist.id, playlists: playlists, audio: audio)
                    } label: {
                        LabeledContent(playlist.name, value: "\(playlist.paths.count)")
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        playlists.delete(playlists.playlists[index].id)
                    }
                }
            }
            .overlay {
                if playlists.playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists", systemImage: "music.note.list",
                        description: Text("Add songs from Files with Add to Playlist."))
                }
            }
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newName = ""
                        creating = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { playlists.create(named: newName) }
            }
        }
    }
}

private struct PlaylistDetailView: View {
    let playlistID: UUID
    @ObservedObject var playlists: PlaylistStore
    @ObservedObject var audio: AudioPlayback

    private var playlist: Playlist? {
        playlists.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        List {
            if let playlist {
                Section {
                    Button {
                        audio.play(playlists.urls(of: playlist))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(playlist.paths.isEmpty)
                }
                Section {
                    ForEach(Array(playlist.paths.enumerated()), id: \.offset) { index, path in
                        Button {
                            let urls = playlists.urls(of: playlist)
                            let name = (path as NSString).lastPathComponent
                            audio.play(urls, startAt: urls.firstIndex { $0.lastPathComponent == name } ?? 0)
                        } label: {
                            Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { playlists.remove(at: $0, from: playlistID) }
                    .onMove { playlists.move(from: $0, to: $1, in: playlistID) }
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar { EditButton() }
    }
}

/// Picks a playlist to add files to, or makes a new one.
struct AddToPlaylistView: View {
    let urls: [URL]
    @ObservedObject var playlists: PlaylistStore
    let files: FileStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var newName = ""

    init(urls: [URL], playlists: PlaylistStore, files: FileStore) {
        self.urls = urls
        self.playlists = playlists
        self.files = files
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    creating = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                ForEach(playlists.playlists) { playlist in
                    Button {
                        playlists.add(urls, to: playlist.id, files: files)
                        dismiss()
                    } label: {
                        LabeledContent(playlist.name, value: "\(playlist.paths.count)")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let playlist = playlists.create(named: newName)
                    playlists.add(urls, to: playlist.id, files: files)
                    dismiss()
                }
            }
        }
    }
}
