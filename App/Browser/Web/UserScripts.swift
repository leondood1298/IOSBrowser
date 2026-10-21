import UIKit
import WebKit

/// The scripts the browser injects into pages and the message channel they report through.
/// Scripts run in the browser's own content world, so pages can't see or tamper with them.
enum UserScripts {
    static let world = WKContentWorld.world(name: "browser")

    /// Adds the scripts and the message handler to `controller`, once. Popup web views can share
    /// their opener's controller, so this is safe to call for every web view.
    static func install(in controller: WKUserContentController) {
        guard ScriptMessageRouter.shared.markInstalled(controller) else { return }
        controller.addUserScript(script("ContextMenuHelper", mainFrameOnly: true))
        controller.addUserScript(script("MediaState", mainFrameOnly: false))
        controller.add(ScriptMessageRouter.shared, contentWorld: world, name: ScriptMessageRouter.mediaHandler)
    }

    private static func script(_ name: String, mainFrameOnly: Bool) -> WKUserScript {
        WKUserScript(
            source: source(named: name), injectionTime: .atDocumentStart,
            forMainFrameOnly: mainFrameOnly, in: world)
    }

    static func source(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            Log.event("Missing user script \(name).js", category: "web")
            return ""
        }
        return source
    }

    /// Lists the page's icon links, largest and touch icons first, for the favicon store.
    static let iconLinksScript = """
        (function () {
          var links = Array.prototype.slice.call(document.querySelectorAll(
            'link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'));
          function size(link) {
            var sizes = (link.getAttribute("sizes") || "").split(/\\s+/).map(function (s) { return parseInt(s, 10) || 0; });
            var best = Math.max.apply(null, sizes.concat([0]));
            return best + (link.rel.indexOf("apple-touch-icon") >= 0 ? 1000 : 0);
          }
          links.sort(function (a, b) { return size(b) - size(a); });
          return links.map(function (link) { return link.href; }).filter(function (href) { return !!href; }).slice(0, 4);
        })();
        """
}

/// Routes script messages from any web view to the tab that owns it.
final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = ScriptMessageRouter()
    static let mediaHandler = "browserMedia"

    private let installed = NSHashTable<WKUserContentController>.weakObjects()
    private let owners = NSMapTable<WKWebView, TabModel>.weakToWeakObjects()

    func markInstalled(_ controller: WKUserContentController) -> Bool {
        if installed.contains(controller) {
            return false
        }
        installed.add(controller)
        return true
    }

    func register(_ tab: TabModel, for webView: WKWebView) {
        owners.setObject(tab, forKey: webView)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = owners.object(forKey: webView) else { return }
        tab.handleScriptMessage(name: message.name, body: message.body)
    }
}
