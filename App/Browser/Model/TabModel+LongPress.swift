import BrowserCore
import UIKit
import WebKit

/// WebKit offers no long-press menu for an image that isn't a link, or for a video, so the tab
/// watches for long presses itself and asks the window to show one. Links keep WebKit's menu,
/// which already includes the image actions when the link is an image.
extension TabModel: UIGestureRecognizerDelegate {
    func addLongPressFallback(to webView: WKWebView) {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        press.minimumPressDuration = 0.6
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delegate = self
        webView.addGestureRecognizer(press)
    }

    @objc private func longPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let webView = recognizer.view as? WKWebView else { return }
        let point = recognizer.location(in: webView)
        Task {
            let result = try? await webView.callAsyncJavaScript(
                "return window.__browserContextInfo ? window.__browserContextInfo() : null;",
                arguments: [:], in: nil, contentWorld: UserScripts.world)
            let info = result as? [String: Any]
            guard info?["link"] as? String == nil,
                  // WebKit showed its own menu for this press.
                  Date().timeIntervalSince(lastContextMenuDate) > 1.5
            else { return }
            if let address = info?["video"] as? String, let mediaURL = URL(string: address),
               let kind = DetectedMedia.kind(
                   of: mediaURL,
                   elementKind: (info?["videoKind"] as? String).flatMap(DetectedMedia.Kind.init(rawValue:)) ?? .video,
                   mimeType: info?["videoType"] as? String) {
                // What the page's detector knows about it (size, protection), if anything.
                let media = detectedMedia.first { $0.url == mediaURL }
                    ?? DetectedMedia(url: mediaURL, kind: kind, pageTitle: pageTitle)
                // The same press may have started WebKit's text selection nearby; the menu replaces it.
                _ = try? await webView.callAsyncJavaScript(
                    "window.getSelection().removeAllRanges();", arguments: [:], in: nil, contentWorld: UserScripts.world)
                delegate?.showVideoMenu(media, at: point, in: webView, from: self)
                return
            }
            guard let image = (info?["image"] as? String).flatMap(URL.init(string:)) else { return }
            delegate?.showImageMenu(image, at: point, in: webView, from: self)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
