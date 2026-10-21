import BrowserCore
import UIKit

/// The media button's picker and its actions: save, play or copy the video and audio found on
/// the page.
extension BrowserViewController {
    func showMediaPicker(from source: UIView) {
        guard let tab = model.selectedTab, !tab.detectedMedia.isEmpty, presentedViewController == nil else { return }
        let media = DetectedMedia.sortedForDisplay(tab.detectedMedia.map { named($0, in: tab) })
        let sizes = MediaSizes()
        let picker = MediaPickerView(
            media: media, sizes: sizes,
            onDownload: { [weak self, weak tab] item in
                guard let self, let tab else { return }
                self.dismiss(animated: true) { self.downloadMedia(item, from: tab) }
            },
            onPlay: { [weak self, weak tab] item in
                guard let self, let tab else { return }
                self.dismiss(animated: true) { self.playMedia(item, from: tab) }
            },
            onCopy: { [weak self] item in
                self?.dismiss(animated: true)
                self?.copyMediaAddress(item)
            })
        let host = UIHostingController(rootView: picker)
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 440, height: min(150 + CGFloat(media.count) * 64, 520))
        if let popover = host.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        present(host, animated: true)

        guard let webView = tab.webView else { return }
        let referer = tab.url
        Task {
            let context = await MediaRequestContext.of(webView)
            sizes.lookUp(media, context: context, referer: referer)
        }
    }

    /// Saves video or audio from the page with the tab's cookies, named after the page when its
    /// address has no file name.
    func downloadMedia(_ media: DetectedMedia, from tab: TabModel) {
        guard media.isDownloadable else {
            explainUnsaveable(media)
            return
        }
        if media.kind == .hls {
            Toast.show("Saving streaming video (HLS) arrives in the next version", systemImage: "film", in: view)
            return
        }
        services.downloads.download(media.url, from: tab, preferredName: media.suggestedFileName)
    }

    /// Plays page media in the app's player, with the page's cookies and user agent.
    func playMedia(_ media: DetectedMedia, from tab: TabModel) {
        let webView = tab.webView
        Task {
            var options: [String: Any] = [:]
            if let webView {
                options = await MediaRequestContext.of(webView).assetOptions(for: media.url)
            }
            VideoPlayback(
                urls: [media.url], index: 0, preferences: services.preferences,
                positions: services.playbackPositions, assetOptions: options
            ).present(from: topController)
        }
    }

    func copyMediaAddress(_ media: DetectedMedia) {
        UIPasteboard.general.url = media.url
        Toast.show("Address copied", systemImage: "doc.on.doc", in: view)
    }

    /// The media with the page's current title (the page may have had none when it was found).
    func named(_ media: DetectedMedia, in tab: TabModel) -> DetectedMedia {
        var media = media
        if !tab.pageTitle.isEmpty {
            media.pageTitle = tab.pageTitle
        }
        return media
    }

    func unsaveableReason(_ media: DetectedMedia) -> String {
        media.isProtected
            ? "This video is copy-protected (DRM), so it can't be saved."
            : "This video streams in small pieces, as on YouTube, so it can't be saved as a file."
    }

    private func explainUnsaveable(_ media: DetectedMedia) {
        let alert = UIAlertController(title: "Can't Save This Video", message: unsaveableReason(media), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
