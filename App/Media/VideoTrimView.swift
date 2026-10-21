import AVFoundation
import AVKit
import BrowserCore
import SwiftUI

/// Trims a video: choose where it starts and ends, then save it as a new file or replace the
/// original. The video isn't re-encoded, so cuts land on the nearest key frame.
struct VideoTrimView: View {
    let url: URL
    let files: FileStore
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var exporting = false
    @State private var errorMessage: String?

    init(url: URL, files: FileStore) {
        self.url = url
        self.files = files
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VideoPlayer(player: player)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if duration > 0 {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Start", value: AudioPlayerView.time(start))
                        Slider(value: $start, in: 0...duration) { editing in
                            if !editing { preview(start) }
                        }
                        LabeledContent("End", value: AudioPlayerView.time(end))
                        Slider(value: $end, in: 0...duration) { editing in
                            if !editing { preview(max(end - 2, 0)) }
                        }
                        Text("New length: \(AudioPlayerView.time(max(end - start, 0)))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: start) { _, value in
                        if value > end - 1 { start = max(end - 1, 0) }
                    }
                    .onChange(of: end) { _, value in
                        if value < start + 1 { end = min(start + 1, duration) }
                    }
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Trim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Save") {
                        Button("Save as New Video") { save(replacing: false) }
                        Button("Replace Original", role: .destructive) { save(replacing: true) }
                    }
                    .disabled(exporting || duration == 0)
                }
            }
            .overlay {
                if exporting {
                    ProgressView("Saving…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert("Couldn't Trim", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                duration = seconds.isFinite ? seconds : 0
                end = duration
            }
        }
    }

    private func preview(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func save(replacing: Bool) {
        let source = url
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let folder = source.deletingLastPathComponent()
        let output = FileNaming.uniqueURL(in: folder, for: "\(stem) (trimmed).\(ext)")
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        exporting = true
        player.pause()
        Task {
            do {
                try await Self.export(source, range: range, to: output)
                if replacing {
                    try FileManager.default.removeItem(at: source)
                    try FileManager.default.moveItem(at: output, to: source)
                }
                files.changed()
                exporting = false
                dismiss()
            } catch {
                try? FileManager.default.removeItem(at: output)
                exporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func export(_ source: URL, range: CMTimeRange, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.timeRange = range
        let ext = output.pathExtension.lowercased()
        let type: AVFileType = ext == "mov" ? .mov : ext == "m4v" ? .m4v : .mp4
        try await session.export(to: output, as: type)
    }
}
