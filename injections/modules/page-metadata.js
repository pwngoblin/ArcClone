// Collects page metadata and reports navigation (including SPA URL changes) to core.
(() => {
  "use strict";
  const arc = window.__arc;
  if (!arc || window.__arcPageMetadata) return;
  window.__arcPageMetadata = true;

  function meta(selector) {
    const el = document.querySelector(selector);
    return el ? (el.getAttribute("content") || "").trim() || null : null;
  }

  function absolute(href) {
    try {
      return href ? new URL(href, document.baseURI).href : null;
    } catch {
      return null;
    }
  }

  function bestFavicon() {
    const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]'));
    let best = null;
    let bestScore = -1;
    for (const link of links) {
      const href = absolute(link.getAttribute("href"));
      if (!href) continue;
      const sizes = (link.getAttribute("sizes") || "").split(/\s+/);
      let size = 16;
      for (const s of sizes) {
        if (s === "any") size = Math.max(size, 256);
        const m = /^(\d+)x(\d+)$/i.exec(s);
        if (m) size = Math.max(size, parseInt(m[1], 10));
      }
      const svgBonus = /\.svg(\?|$)/i.test(href) ? 64 : 0;
      // Prefer something close to 32px for sidebar rendering; svg scales cleanly.
      const score = svgBonus + (size >= 32 ? 200 - Math.abs(size - 64) : size);
      if (score > bestScore) {
        best = href;
        bestScore = score;
      }
    }
    return best || absolute("/favicon.ico");
  }

  function collect() {
    return {
      url: location.href,
      title: (document.title || "").trim(),
      description: meta('meta[name="description"]') || meta('meta[property="og:description"]'),
      siteName: meta('meta[property="og:site_name"]'),
      image: absolute(meta('meta[property="og:image"]')),
      type: meta('meta[property="og:type"]'),
      canonical: absolute((document.querySelector('link[rel="canonical"]') || {}).href),
      favicon: bestFavicon(),
      lang: document.documentElement.lang || null,
      themeColor: meta('meta[name="theme-color"]'),
    };
  }

  arc.register("page.metadata", collect);

  let lastURL = location.href;
  let lastTitle = document.title;

  function report(reason) {
    arc.emit("page.didChange", { reason, ...collect() });
  }

  report("load");

  // DOM events cross content-world boundaries, so these work from the isolated world.
  window.addEventListener("popstate", () => check("popstate"));
  window.addEventListener("hashchange", () => check("hashchange"));
  document.addEventListener("yt-navigate-finish", () => setTimeout(() => check("spa"), 50));

  // history.pushState patched in the page world is invisible here, so poll cheaply.
  setInterval(() => check("poll"), 1000);

  const titleEl = document.querySelector("title");
  if (titleEl) {
    new MutationObserver(() => check("title")).observe(titleEl, { childList: true, characterData: true, subtree: true });
  }

  function check(reason) {
    if (location.href !== lastURL || document.title !== lastTitle) {
      lastURL = location.href;
      lastTitle = document.title;
      report(reason);
    }
  }
})();
