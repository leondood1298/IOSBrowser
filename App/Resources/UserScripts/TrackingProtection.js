/* Adapted from Firefox Focus for iOS (preload.js and postload.js), Mozilla Public License 2.0.
 * Reports the URLs a page tries to load so the browser can count blocked trackers: WebKit's
 * content blocker blocks them but doesn't say what it blocked. Runs in the page's own world
 * (to see its XHR, fetch and image requests) in every frame. */
(function () {
  "use strict";
  if (window.__browserTrackingProtection) { return; }
  Object.defineProperty(window, "__browserTrackingProtection", { value: true });
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserTrackers;
  if (!handler) { return; }
  var seen = new Set();

  function report(url) {
    if (!url || typeof url !== "string") { return; }
    var absolute;
    try { absolute = new URL(url, document.baseURI).href; } catch (error) { return; }
    if (absolute.indexOf("http") !== 0 || seen.has(absolute)) { return; }
    seen.add(absolute);
    try { handler.postMessage({ url: absolute }); } catch (error) {}
  }

  var originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    report(String(url));
    return originalOpen.apply(this, arguments);
  };

  if (window.fetch) {
    var originalFetch = window.fetch;
    window.fetch = function (input) {
      try { report(typeof input === "string" ? input : (input && input.url)); } catch (error) {}
      return originalFetch.apply(this, arguments);
    };
  }

  if (navigator.sendBeacon) {
    var originalBeacon = navigator.sendBeacon;
    navigator.sendBeacon = function (url) {
      report(String(url));
      return originalBeacon.apply(this, arguments);
    };
  }

  var imageSource = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, "src");
  if (imageSource && imageSource.set) {
    Object.defineProperty(HTMLImageElement.prototype, "src", {
      configurable: true,
      enumerable: imageSource.enumerable,
      get: imageSource.get,
      set: function (value) {
        report(String(value));
        imageSource.set.call(this, value);
      }
    });
  }

  function scan(node) {
    if (!node || node.nodeType !== 1) { return; }
    var tag = node.tagName;
    if (tag === "SCRIPT" || tag === "IMG" || tag === "IFRAME") { report(node.src); }
    if (node.querySelectorAll) {
      node.querySelectorAll("script[src], img[src], iframe[src]").forEach(function (element) { report(element.src); });
    }
  }

  new MutationObserver(function (mutations) {
    mutations.forEach(function (mutation) { mutation.addedNodes.forEach(scan); });
  }).observe(document.documentElement || document, { childList: true, subtree: true });

  document.addEventListener("DOMContentLoaded", function () { scan(document.documentElement); });
})();
