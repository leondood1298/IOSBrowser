import BrowserCore
import SwiftUI

/// The video and audio found on the page, opened from the address bar's media button: save,
/// play or copy each one. What can't be saved (media streamed in pieces, or copy-protected) is
/// listed with the reason.
struct MediaPickerView: View {
    let media: [DetectedMedia]
    @ObservedObject var sizes: MediaSizes
    var onDownload: (DetectedMedia) -> Void
    var onPlay: (DetectedMedia) -> Void
    var onCopy: (DetectedMedia) -> Void

    private var saveable: [DetectedMedia] { media.filter(\.isDownloadable) }
    private var unsaveable: [DetectedMedia] { media.filter { !$0.isDownloadable } }

    var body: some View {
        NavigationStack {
            List {
                if !saveable.isEmpty {
                    Section {
                        ForEach(saveable) { row($0) }
                    }
                }
                if !unsaveable.isEmpty {
                    Section {
                        ForEach(unsaveable) { row($0) }
                    } footer: {
                        Text(explanation)
                    }
                }
            }
            .navigationTitle("Video and Audio")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("mediaPicker")
    }

    private var explanation: String {
        if unsaveable.contains(where: \.isProtected) {
            return "Copy-protected (DRM) media can't be saved. Media that streams in small pieces, as on YouTube, "
                + "can't be saved as a file either; it still plays on the page and in picture in picture."
        }
        return "This media streams in small pieces, as on YouTube, so it can't be saved as a file. "
            + "It still plays on the page and in picture in picture."
    }

    private func row(_ item: DetectedMedia) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: item))
                .font(.title2)
                .foregroundStyle(item.isDownloadable ? Color.accentColor : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isDownloadable ? item.suggestedFileName : (item.url.host ?? item.suggestedFileName))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if item.isDownloadable {
                Button {
                    onDownload(item)
                } label: {
                    Image(systemName: "arrow.down.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download")
                .accessibilityIdentifier("mediaDownload-\(item.suggestedFileName)")
            }
            if item.kind != .stream {
                Menu {
                    if !item.isProtected {
                        Button("Play", systemImage: "play.fill") { onPlay(item) }
                    }
                    Button("Copy Address", systemImage: "doc.on.doc") { onCopy(item) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("More")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("media-\(item.suggestedFileName)")
    }

    private func symbol(for item: DetectedMedia) -> String {
        if item.isProtected { return "lock.rectangle" }
        switch item.kind {
        case .video: return "film"
        case .audio: return "music.note"
        case .hls: return "play.rectangle.on.rectangle"
        case .stream: return "rectangle.badge.xmark"
        }
    }

    private func detail(for item: DetectedMedia) -> String {
        if item.isProtected {
            return "Copy-protected (DRM)"
        }
        var parts: [String] = []
        switch item.kind {
        case .video: parts.append("Video")
        case .audio: parts.append("Audio")
        case .hls: parts.append("Streaming video (HLS)")
        case .stream: return "Streams in pieces"
        }
        if let quality = item.qualityLabel {
            parts.append(quality)
        }
        if let size = sizes.bytes[item.url] {
            parts.append(DownloadFormatting.bytes(size))
        }
        if let duration = item.duration {
            parts.append(MediaFormatting.duration(duration))
        }
        return parts.joined(separator: " · ")
    }
}
