import UIKit
import WebKit

/// WebKit offers no long-press menu for an image that isn't a link, so the tab watches for long
/// presses itself and asks the window to show one. Links keep WebKit's menu, which already
/// includes the image actions when the link is an image.
extension TabModel: UIGestureRecognizerDelegate {
    func addImageLongPress(to webView: WKWebView) {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(imageLongPress(_:)))
        press.minimumPressDuration = 0.6
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delegate = self
        webView.addGestureRecognizer(press)
    }

    @objc private func imageLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let webView = recognizer.view as? WKWebView else { return }
        let point = recognizer.location(in: webView)
        Task {
            let result = try? await webView.callAsyncJavaScript(
                "return window.__browserContextInfo ? window.__browserContextInfo() : null;",
                arguments: [:], in: nil, contentWorld: UserScripts.world)
            let info = result as? [String: Any]
            guard info?["link"] as? String == nil,
                  let image = (info?["image"] as? String).flatMap(URL.init(string:)),
                  // WebKit showed its own menu for this press.
                  Date().timeIntervalSince(lastContextMenuDate) > 1.5
            else { return }
            delegate?.showImageMenu(image, at: point, in: webView, from: self)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
