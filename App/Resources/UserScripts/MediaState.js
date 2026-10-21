// Tells the browser whether this frame is playing media with sound (for the tab's speaker icon)
// and mutes media when the tab is muted. Runs in every frame, in the browser's content world.
// The mute command spreads to child frames with postMessage, which works across origins.
(function () {
  "use strict";
  if (window.__browserSetMuted) { return; }
  var frameId = Math.random().toString(36).slice(2);
  var muted = false;
  var mutedByUs = new WeakSet();
  var lastReport = "";

  function mediaElements() {
    return document.querySelectorAll("video, audio");
  }

  function report() {
    var playing = false;
    var audible = false;
    mediaElements().forEach(function (media) {
      if (!media.paused && !media.ended) {
        playing = true;
        if (!media.muted && media.volume > 0) { audible = true; }
      }
    });
    var key = playing + ":" + audible;
    if (key === lastReport) { return; }
    lastReport = key;
    try {
      window.webkit.messageHandlers.browserMedia.postMessage({ frame: frameId, playing: playing, audible: audible });
    } catch (error) {}
  }

  function muteElement(media) {
    if (!media.muted) {
      media.muted = true;
      mutedByUs.add(media);
    }
  }

  function setMuted(value) {
    if (muted === value) { return; }
    muted = value;
    mediaElements().forEach(function (media) {
      if (value) {
        muteElement(media);
      } else if (mutedByUs.has(media)) {
        media.muted = false;
        mutedByUs.delete(media);
      }
    });
    for (var i = 0; i < window.frames.length; i++) {
      try { window.frames[i].postMessage({ __browserSetMuted: value }, "*"); } catch (error) {}
    }
    report();
  }

  ["play", "playing", "pause", "ended", "volumechange", "emptied"].forEach(function (type) {
    document.addEventListener(type, function (event) {
      if (muted && (type === "play" || type === "playing") && event.target && "muted" in event.target) {
        muteElement(event.target);
      }
      report();
    }, true);
  });

  window.addEventListener("message", function (event) {
    if (event.data && typeof event.data.__browserSetMuted === "boolean") {
      setMuted(event.data.__browserSetMuted);
    }
  });

  window.addEventListener("pagehide", function () {
    lastReport = "";
    try {
      window.webkit.messageHandlers.browserMedia.postMessage({ frame: frameId, playing: false, audible: false });
    } catch (error) {}
  });

  window.__browserSetMuted = setMuted;
})();
