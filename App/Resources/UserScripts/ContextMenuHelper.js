// Remembers what is under the finger when a touch starts, so the native long-press menu can
// offer image actions. Runs in the browser's own content world; read with __browserContextInfo().
(function () {
  "use strict";
  if (window.__browserContextInfo) { return; }
  var last = null;

  function describe(target) {
    var info = { image: null, link: null, title: null };
    for (var el = target; el && el.nodeType === 1; el = el.parentElement) {
      if (!info.image && el.tagName === "IMG" && (el.currentSrc || el.src)) {
        info.image = el.currentSrc || el.src;
        info.title = el.alt || el.title || null;
      }
      if (!info.link && el.tagName === "A" && typeof el.href === "string" && el.href) {
        info.link = el.href;
      }
    }
    return info;
  }

  document.addEventListener("pointerdown", function (event) {
    if (event.isPrimary) { last = describe(event.target); }
  }, { capture: true, passive: true });
  document.addEventListener("touchstart", function (event) {
    last = event.touches.length === 1 ? describe(event.target) : null;
  }, { capture: true, passive: true });

  window.__browserContextInfo = function () { return last; };
})();
