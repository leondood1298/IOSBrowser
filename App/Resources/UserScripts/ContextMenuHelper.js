// Remembers what is under the finger when a touch starts, so the native long-press menu can
// offer image and video actions. Runs in the browser's own content world; read with
// __browserContextInfo().
(function () {
  "use strict";
  if (window.__browserContextInfo) { return; }
  var last = null;

  function mediaSource(media) {
    var source = media.currentSrc || media.getAttribute("src");
    var type = "";
    if (!source) {
      var child = media.querySelector("source[src]");
      if (child) {
        source = child.src;
        type = child.getAttribute("type") || "";
      }
    }
    if (!source) { return null; }
    try { return { url: new URL(source, document.baseURI).href, type: type }; } catch (error) { return null; }
  }

  // Players often cover the video with their own controls, so look under the finger as well.
  function videoAt(x, y) {
    if (typeof x !== "number" || !document.elementsFromPoint) { return null; }
    var elements = document.elementsFromPoint(x, y);
    for (var i = 0; i < elements.length; i++) {
      if (elements[i].tagName === "VIDEO") { return elements[i]; }
    }
    return null;
  }

  function describe(target, x, y) {
    var info = { image: null, link: null, title: null, video: null, videoKind: null, videoType: null };
    var media = null;
    for (var el = target; el && el.nodeType === 1; el = el.parentElement) {
      if (!info.image && el.tagName === "IMG" && (el.currentSrc || el.src)) {
        info.image = el.currentSrc || el.src;
        info.title = el.alt || el.title || null;
      }
      if (!info.link && el.tagName === "A" && typeof el.href === "string" && el.href) {
        info.link = el.href;
      }
      if (!media && (el.tagName === "VIDEO" || el.tagName === "AUDIO")) {
        media = el;
      }
    }
    media = media || videoAt(x, y);
    var source = media ? mediaSource(media) : null;
    if (source) {
      info.video = source.url;
      info.videoType = source.type;
      info.videoKind = media.tagName === "AUDIO" ? "audio" : "video";
    }
    return info;
  }

  document.addEventListener("pointerdown", function (event) {
    if (event.isPrimary) { last = describe(event.target, event.clientX, event.clientY); }
  }, { capture: true, passive: true });
  document.addEventListener("touchstart", function (event) {
    var touch = event.touches.length === 1 ? event.touches[0] : null;
    last = touch ? describe(event.target, touch.clientX, touch.clientY) : null;
  }, { capture: true, passive: true });

  window.__browserContextInfo = function () { return last; };
})();
