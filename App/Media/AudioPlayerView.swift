import SwiftUI

/// The full music player: artwork, the song, a scrubber, controls and the queue.
struct AudioPlayerView: View {
    @ObservedObject var audio: AudioPlayback
    @ObservedObject var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showingPlaylists = false

    init(audio: AudioPlayback, playlists: PlaylistStore) {
        self.audio = audio
        self.playlists = playlists
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                artwork
                VStack(spacing: 4) {
                    Text(audio.title.isEmpty ? "Not Playing" : audio.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("audioTitle")
                    if !audio.artist.isEmpty {
                        Text(audio.artist).foregroundStyle(.secondary)
                    }
                }
                scrubber
                controls
                queueList
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("audioDoneButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingPlaylists = true
                    } label: {
                        Label("Playlists", systemImage: "music.note.list")
                    }
                }
            }
            .sheet(isPresented: $showingPlaylists) {
                PlaylistsView(playlists: playlists, audio: audio)
            }
        }
    }

    private var artwork: some View {
        Group {
            if let image = audio.artwork {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 72))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 8, y: 4)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { scrubbing ?? audio.elapsed }, set: { scrubbing = $0 }),
                in: 0...max(audio.duration, 1)
            ) { editing in
                if !editing, let value = scrubbing {
                    audio.seek(to: value)
                    scrubbing = nil
                }
            }
            HStack {
                Text(Self.time(scrubbing ?? audio.elapsed))
                Spacer()
                Text("−" + Self.time(max(audio.duration - (scrubbing ?? audio.elapsed), 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 34) {
            Button { audio.shuffle.toggle() } label: {
                Image(systemName: "shuffle").foregroundStyle(audio.shuffle ? Color.accentColor : .secondary)
            }
            .accessibilityLabel("Shuffle")
            Button { audio.previous() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button { audio.togglePlayPause() } label: {
                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 60))
            }
            .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("audioPlayPause")
            Button { audio.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
            Button { audio.cycleRepeat() } label: {
                Image(systemName: audio.repeatMode.symbol)
                    .foregroundStyle(audio.repeatMode == .off ? Color.secondary : Color.accentColor)
            }
            .accessibilityLabel("Repeat")
        }
        .font(.title2)
        .buttonStyle(.plain)
    }

    private var queueList: some View {
        List {
            Section("Up Next") {
                ForEach(Array(audio.queue.enumerated()), id: \.offset) { index, url in
                    Button {
                        audio.select(index)
                    } label: {
                        HStack {
                            Image(systemName: index == audio.index ? "speaker.wave.2.fill" : "music.note")
                                .foregroundStyle(index == audio.index ? Color.accentColor : .secondary)
                                .frame(width: 24)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// The bar at the bottom of the browser while music plays.
struct MiniPlayerView: View {
    @ObservedObject var audio: AudioPlayback
    var onOpen: () -> Void

    init(audio: AudioPlayback, onOpen: @escaping () -> Void) {
        self.audio = audio
        self.onOpen = onOpen
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image = audio.artwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(audio.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !audio.artist.isEmpty {
                    Text(audio.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { audio.togglePlayPause() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
            Button { audio.next() } label: { Image(systemName: "forward.fill").font(.title3) }
                .accessibilityLabel("Next")
            Button { audio.stop() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                .accessibilityLabel("Stop")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityIdentifier("miniPlayer")
    }
}
