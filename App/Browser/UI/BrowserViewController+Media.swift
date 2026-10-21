import BrowserCore
import SwiftUI
import UIKit

/// The media button's picker and its actions: save, play or copy the video and audio found on
/// the page.
extension BrowserViewController {
    func showMediaPicker(from source: UIView) {
        guard let tab = model.selectedTab, !tab.detectedMedia.isEmpty, presentedViewController == nil else { return }
        let media = DetectedMedia.sortedForDisplay(DetectedMedia.collapsingPlaylists(tab.detectedMedia).map { named($0, in: tab) })
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
        // Room for the title, the rows and, when something can't be saved, the note under them.
        let note: CGFloat = media.contains { !$0.isDownloadable } ? 90 : 0
        host.preferredContentSize = CGSize(width: 440, height: min(130 + CGFloat(media.count) * 66 + note, 560))
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
            saveStream(media, from: tab)
            return
        }
        services.downloads.download(media.url, from: tab, preferredName: media.suggestedFileName)
    }

    /// Reads the stream's playlist (asking for the quality when there are several), confirms the
    /// name and folder, and hands it to the download manager.
    private func saveStream(_ media: DetectedMedia, from tab: TabModel) {
        Task {
            var request = StreamRequest(cookies: [], userAgent: nil, referer: tab.url)
            if let webView = tab.webView {
                request = await MediaRequestContext.of(webView).streamRequest(referer: tab.url)
            }
            do {
                let job = try await StreamJob.make(for: media.url, request: request) { [weak self] variants in
                    await self?.chooseQuality(variants)
                }
                guard let job else { return }
                var name = media.suggestedFileName
                var folder = services.downloads.defaultFolder(forFileNamed: name, mimeType: "video/mp4")
                if services.preferences.confirmDownloads {
                    let choice = await DownloadConfirmation.ask(
                        from: topController, fileName: name, size: nil, mimeType: "video/mp4", folder: folder)
                    guard let choice else { return }
                    name = choice.fileName
                    folder = choice.folder
                }
                services.downloads.startStream(job, fileName: name, folder: folder, sourceURL: media.url, from: tab, request: request)
            } catch {
                let alert = UIAlertController(title: "Can't Save This Video", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                topController.present(alert, animated: true)
            }
        }
    }

    /// Asks which quality of a stream to save; nil when cancelled.
    private func chooseQuality(_ variants: [HLSVariant]) async -> HLSVariant? {
        await withCheckedContinuation { continuation in
            let sheet = UIAlertController(title: "Choose a Quality", message: nil, preferredStyle: .actionSheet)
            for variant in variants {
                let rate = HLSVariant.bitRate(variant.averageBandwidth ?? variant.bandwidth)
                let title = variant.qualityLabel == rate ? rate : "\(variant.qualityLabel) · \(rate)"
                sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                    continuation.resume(returning: variant)
                })
            }
            // On iPad, tapping outside the popover also runs the Cancel action.
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = addressField
                popover.sourceRect = addressField.bounds
            }
            topController.present(sheet, animated: true)
        }
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
