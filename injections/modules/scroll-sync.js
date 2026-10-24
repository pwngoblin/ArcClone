// Link Scrolling for split view: while native links this page to others in its split, reports
// where it's scrolled to (as a fraction of how far it can scroll, so pages of different lengths
// stay in step) and scrolls to where the other panes are. Nothing listens while unlinked.
(() => {
  "use strict";
  const lily = window.__lily;
  if (!lily || !lily.isMainFrame || window.__lilyScrollSync) return;
  window.__lilyScrollSync = true;

  // Scroll events caused by applying another pane's position aren't sent back.
  const ECHO_MS = 120;
  let linked = false;
  let frame = 0;
  let quietUntil = 0;

  const root = () => document.scrollingElement || document.documentElement;
  const clamp = (value) => Math.min(1, Math.max(0, Number(value) || 0));

  function position() {
    const element = root();
    const maxX = element.scrollWidth - window.innerWidth;
    const maxY = element.scrollHeight - window.innerHeight;
    return { x: maxX > 0 ? clamp(window.scrollX / maxX) : 0, y: maxY > 0 ? clamp(window.scrollY / maxY) : 0 };
  }

  // At most once per frame, and only for scrolls this pane made.
  function onScroll() {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      if (linked && performance.now() >= quietUntil) lily.emit("scroll.changed", position());
    });
  }

  lily.register("scroll.link", ({ on } = {}) => {
    const next = on === true;
    if (next !== linked) {
      linked = next;
      if (linked) window.addEventListener("scroll", onScroll, { passive: true });
      else window.removeEventListener("scroll", onScroll);
    }
    return { linked };
  });

  lily.register("scroll.apply", ({ x, y } = {}) => {
    if (!linked) return { applied: false };
    const element = root();
    quietUntil = performance.now() + ECHO_MS;
    window.scrollTo({
      left: clamp(x) * Math.max(0, element.scrollWidth - window.innerWidth),
      top: clamp(y) * Math.max(0, element.scrollHeight - window.innerHeight),
      behavior: "instant",
    });
    return { applied: true };
  });
})();
