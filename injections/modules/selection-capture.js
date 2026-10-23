// Reports meaningful text selections to core so the assistant can offer "ask about selection".
(() => {
  "use strict";
  const arc = window.__arc;
  if (!arc || window.__arcSelectionCapture) return;
  window.__arcSelectionCapture = true;

  const MIN_CHARS = 3;
  const MAX_CHARS = 20000;
  let timer = null;
  let last = "";

  function current() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) return "";
    const active = document.activeElement;
    // Never report text typed into password or form fields.
    if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)) return "";
    return sel.toString().trim();
  }

  document.addEventListener("selectionchange", () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      const text = current();
      if (text === last) return;
      last = text;
      if (!text) {
        arc.emit("selection.cleared", { url: location.href });
        return;
      }
      if (text.length < MIN_CHARS) return;
      arc.emit("selection.changed", {
        url: location.href,
        text: text.slice(0, MAX_CHARS),
        truncated: text.length > MAX_CHARS,
        mainFrame: arc.isMainFrame,
      });
    }, 350);
  });
})();
