// Lily dark mode for websites.
// "forced": if the page is still light after WebKit asked for its dark theme, invert it with a
// CSS filter and re-invert media so photos and video keep their real colours.
(() => {
  "use strict";
  const lily = window.__lily;
  if (!lily) return;

  const STYLE_ID = "lily-force-dark";
  const CSS = `
    html { filter: invert(0.92) hue-rotate(180deg) !important; background: #0f0f10 !important; }
    img, video, picture, canvas, iframe, embed, object, svg image,
    [style*="background-image"] { filter: invert(1) hue-rotate(180deg) !important; }
  `;

  function luminance(color) {
    const m = color.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/);
    if (!m) return null;
    if (m[4] !== undefined && Number(m[4]) < 0.1) return null; // transparent
    const [r, g, b] = [m[1], m[2], m[3]].map((v) => {
      const c = Number(v) / 255;
      return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  /** True when the page paints a light background (so it has no dark theme of its own). */
  function looksLight() {
    for (const el of [document.body, document.documentElement]) {
      if (!el) continue;
      const l = luminance(getComputedStyle(el).backgroundColor);
      if (l !== null) return l > 0.5;
    }
    return true; // no background set: the canvas default is white
  }

  function apply(mode) {
    const existing = document.getElementById(STYLE_ID);
    existing?.remove();
    if (mode !== "forced") return { applied: false };
    const target = document.head || document.documentElement;
    if (!target || !looksLight()) return { applied: false };
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = CSS;
    target.appendChild(style);
    return { applied: true };
  }

  lily.register("darkMode.apply", ({ mode } = {}) => apply(mode));
})();
