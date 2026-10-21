// Finds the video and audio on a page for the browser's media button: media elements and their
// sources, and media or playlist files the page fetched. Fetches come from resource timing, which
// also sees the playlists that Media Source players (hls.js and the like) load with XHR or fetch.
// Runs in every frame, in the browser's content world, and reports in batches.
(function () {
  "use strict";
  if (window.__browserMediaDetector) { return; }
  window.__browserMediaDetector = true;

  var reported = Object.create(null);
  var pending = [];
  var flushTimer = null;
  var scanTimer = null;
  var sawPlaylist = false;
  var protectedElements = new WeakSet();
  // Files worth listing from requests. Segments (.ts, .m4s) are left out: they're pieces of a
  // playlist that's listed instead.
  var requestPattern = /\.(m3u8|mpd|mp4|m4v|mov|webm|mp3|m4a|aac|oga|ogg|opus|flac|wav)(\?|#|$)/i;
  var playlistPattern = /\.(m3u8|mpd)(\?|#|$)/i;

  function absolute(url) {
    try { return new URL(url, document.baseURI).href; } catch (error) { return null; }
  }

  function queue(item) {
    // The same address is reported again once more is known about it (size, protection).
    var key = item.url + "|" + item.width + "x" + item.height + "|" + item.drm;
    if (reported[key]) { return; }
    reported[key] = true;
    pending.push(item);
    if (!flushTimer) { flushTimer = setTimeout(flush, 300); }
  }

  function flush() {
    flushTimer = null;
    var items = pending.splice(0, 40);
    if (pending.length) { flushTimer = setTimeout(flush, 300); }
    if (!items.length) { return; }
    try {
      window.webkit.messageHandlers.browserMediaFound.postMessage({ items: items });
    } catch (error) {}
  }

  function inspect(media) {
    var element = media.tagName === "AUDIO" ? "audio" : "video";
    var base = {
      element: element,
      width: media.videoWidth || 0,
      height: media.videoHeight || 0,
      duration: isFinite(media.duration) ? media.duration : 0,
      drm: !!media.mediaKeys || protectedElements.has(media)
    };
    var sources = [];
    var current = media.currentSrc || media.getAttribute("src");
    if (current) { sources.push({ url: current, type: "" }); }
    var children = media.querySelectorAll("source[src]");
    for (var i = 0; i < children.length; i++) {
      sources.push({ url: children[i].getAttribute("src"), type: children[i].getAttribute("type") || "" });
    }
    sources.forEach(function (source) {
      var url = absolute(source.url);
      if (!url || url.indexOf("data:") === 0) { return; }
      queue({
        url: url, element: base.element, type: source.type, width: base.width, height: base.height,
        duration: base.duration, drm: base.drm
      });
    });
  }

  function scanElements() {
    scanTimer = null;
    var media = document.querySelectorAll("video, audio");
    for (var i = 0; i < media.length; i++) { inspect(media[i]); }
  }

  function scheduleScan() {
    if (!scanTimer) { scanTimer = setTimeout(scanElements, 500); }
  }

  function inspectRequest(entry) {
    var url = entry.name;
    if (!url || url.indexOf("http") !== 0 || !requestPattern.test(url)) { return; }
    if (playlistPattern.test(url)) {
      sawPlaylist = true;
    } else if (sawPlaylist && (entry.initiatorType === "xmlhttprequest" || entry.initiatorType === "fetch")) {
      // Most likely a segment of the playlist found earlier.
      return;
    }
    queue({ url: url, element: "", type: "", width: 0, height: 0, duration: 0, drm: false });
  }

  ["loadstart", "loadedmetadata", "play", "emptied"].forEach(function (type) {
    document.addEventListener(type, function (event) {
      var target = event.target;
      if (target && (target.tagName === "VIDEO" || target.tagName === "AUDIO")) { inspect(target); }
    }, true);
  });
  // Encrypted media (DRM) asks for keys before mediaKeys is set.
  document.addEventListener("encrypted", function (event) {
    var target = event.target;
    if (target && (target.tagName === "VIDEO" || target.tagName === "AUDIO")) {
      protectedElements.add(target);
      inspect(target);
    }
  }, true);

  try {
    performance.getEntriesByType("resource").forEach(inspectRequest);
    new PerformanceObserver(function (list) {
      list.getEntries().forEach(inspectRequest);
    }).observe({ type: "resource", buffered: true });
  } catch (error) {}

  new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      var nodes = records[i].addedNodes;
      for (var j = 0; j < nodes.length; j++) {
        var node = nodes[j];
        if (node.nodeType !== 1) { continue; }
        var tag = node.tagName;
        if (tag === "VIDEO" || tag === "AUDIO" || tag === "SOURCE" ||
            (node.firstElementChild && node.querySelector("video, audio"))) {
          scheduleScan();
          return;
        }
      }
    }
  }).observe(document, { childList: true, subtree: true });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", scanElements);
  } else {
    scanElements();
  }
})();
