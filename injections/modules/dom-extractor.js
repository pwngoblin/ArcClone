// Readable-content extraction for the agent: main text, outline, selection, links.
// A self-contained heuristic extractor (paragraph scoring + link-density penalty).
(() => {
  "use strict";
  const lily = window.__lily;
  if (!lily || window.__lilyDomExtractor) return;
  window.__lilyDomExtractor = true;

  const DEFAULT_MAX_CHARS = 60000;
  const UNLIKELY = /banner|breadcrumb|combx|comment|community|cookie|disqus|extra|footer|gdpr|header|legends|menu|modal|related|remark|replies|rss|shoutbox|sidebar|skyscraper|social|sponsor|ad-break|agegate|pagination|pager|popup|newsletter|subscribe/i;
  const LIKELY = /and|article|body|column|content|main|shadow|story|entry|post|text|blog/i;
  const POSITIVE = /article|body|content|entry|hentry|h-entry|main|page|post|text|blog|story/i;
  const NEGATIVE = /hidden|^hid$|hid$|hid |^hid |banner|combx|comment|com-|contact|foot|footer|footnote|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget/i;
  const SKIP_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "FORM", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "NAV", "ASIDE", "FOOTER"]);
  const BLOCK_TAGS = new Set(["P", "DIV", "SECTION", "ARTICLE", "MAIN", "LI", "TD", "PRE", "BLOCKQUOTE", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "TABLE", "TR", "FIGCAPTION", "DD", "DT"]);

  function isVisible(el) {
    if (!(el instanceof Element)) return true;
    if (el.hidden || el.getAttribute("aria-hidden") === "true") return false;
    const style = getComputedStyle(el);
    return style.display !== "none" && style.visibility !== "hidden";
  }

  function classAndId(el) {
    return `${el.className && typeof el.className === "string" ? el.className : ""} ${el.id || ""}`;
  }

  function textLength(el) {
    return (el.textContent || "").replace(/\s+/g, " ").trim().length;
  }

  function linkDensity(el) {
    const total = textLength(el);
    if (!total) return 0;
    let linkLen = 0;
    for (const a of el.querySelectorAll("a")) linkLen += textLength(a);
    return linkLen / total;
  }

  function weight(el) {
    const ci = classAndId(el);
    let w = 0;
    if (NEGATIVE.test(ci)) w -= 25;
    if (POSITIVE.test(ci)) w += 25;
    return w;
  }

  function findContentRoot() {
    const semantic = document.querySelector("article, main, [role='main'], [itemprop='articleBody']");
    if (semantic && textLength(semantic) > 500 && linkDensity(semantic) < 0.5) return semantic;

    const scores = new Map();
    const paragraphs = document.querySelectorAll("p, pre, td, blockquote, li");
    for (const p of paragraphs) {
      const len = textLength(p);
      if (len < 25) continue;
      const ci = classAndId(p.parentElement || p);
      if (UNLIKELY.test(ci) && !LIKELY.test(ci)) continue;
      let score = 1 + (p.textContent.split(/[,，、]/).length) + Math.min(Math.floor(len / 100), 3);
      let ancestor = p.parentElement;
      let level = 0;
      while (ancestor && level < 3 && ancestor !== document.documentElement) {
        if (!scores.has(ancestor)) scores.set(ancestor, weight(ancestor) + (ancestor.tagName === "DIV" ? 5 : 0));
        const divider = level === 0 ? 1 : level === 1 ? 2 : level * 3;
        scores.set(ancestor, scores.get(ancestor) + score / divider);
        ancestor = ancestor.parentElement;
        level += 1;
      }
    }

    let best = null;
    let bestScore = 0;
    for (const [el, raw] of scores) {
      const adjusted = raw * (1 - linkDensity(el));
      if (adjusted > bestScore) {
        best = el;
        bestScore = adjusted;
      }
    }
    return best || document.body;
  }

  // Serialise a subtree to lightweight markdown-ish text that LLMs read well.
  function serialise(root, maxChars) {
    const out = [];
    let length = 0;
    let truncated = false;

    function push(s) {
      if (truncated) return;
      if (length + s.length > maxChars) {
        out.push(s.slice(0, Math.max(0, maxChars - length)));
        truncated = true;
        return;
      }
      out.push(s);
      length += s.length;
    }

    function walk(node, listDepth) {
      if (truncated) return;
      if (node.nodeType === Node.TEXT_NODE) {
        const t = node.nodeValue.replace(/\s+/g, " ");
        if (t.trim()) push(t);
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      if (SKIP_TAGS.has(el.tagName) || !isVisible(el)) return;
      const ci = classAndId(el);
      if (el !== root && UNLIKELY.test(ci) && !LIKELY.test(ci) && linkDensity(el) > 0.3) return;

      const tag = el.tagName;
      const heading = /^H([1-6])$/.exec(tag);
      if (heading) {
        push(`\n\n${"#".repeat(Number(heading[1]))} ${el.textContent.replace(/\s+/g, " ").trim()}\n\n`);
        return;
      }
      if (tag === "BR") return push("\n");
      if (tag === "PRE") return push(`\n\n\`\`\`\n${el.textContent.trim()}\n\`\`\`\n\n`);
      if (tag === "IMG") {
        const alt = (el.getAttribute("alt") || "").trim();
        if (alt) push(` [image: ${alt}] `);
        return;
      }
      if (tag === "LI") push(`\n${"  ".repeat(Math.max(0, listDepth - 1))}- `);
      if (tag === "BLOCKQUOTE") push("\n\n> ");
      if (tag === "TR") push("\n| ");

      const childDepth = tag === "UL" || tag === "OL" ? listDepth + 1 : listDepth;
      for (const child of el.childNodes) walk(child, childDepth);

      if (tag === "TD" || tag === "TH") push(" | ");
      else if (BLOCK_TAGS.has(tag) && tag !== "LI") push("\n\n");
    }

    walk(root, 0);
    const text = out.join("").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").replace(/[ \t]{2,}/g, " ").trim();
    return { text, truncated };
  }

  function outline() {
    return Array.from(document.querySelectorAll("h1, h2, h3"))
      .filter(isVisible)
      .map((h) => ({ level: Number(h.tagName[1]), text: h.textContent.replace(/\s+/g, " ").trim(), id: h.id || null }))
      .filter((h) => h.text)
      .slice(0, 200);
  }

  function byline() {
    const el = document.querySelector("[rel='author'], [itemprop='author'], .byline, .author, meta[name='author']");
    if (!el) return null;
    const v = el.tagName === "META" ? el.getAttribute("content") : el.textContent;
    return v ? v.replace(/\s+/g, " ").trim().slice(0, 200) : null;
  }

  function selectionText() {
    const sel = window.getSelection();
    return sel ? sel.toString().trim() : "";
  }

  function extract(args) {
    const maxChars = Math.max(1000, Math.min(Number(args && args.maxChars) || DEFAULT_MAX_CHARS, 500000));
    const root = findContentRoot();
    const { text, truncated } = serialise(root, maxChars);
    return {
      url: location.href,
      title: (document.title || "").trim(),
      byline: byline(),
      lang: document.documentElement.lang || null,
      text,
      truncated,
      wordCount: text ? text.split(/\s+/).length : 0,
      outline: outline(),
      selection: selectionText() || null,
      extractedAt: new Date().toISOString(),
    };
  }

  function links(args) {
    const limit = Math.min(Number(args && args.limit) || 200, 2000);
    const seen = new Set();
    const result = [];
    for (const a of document.querySelectorAll("a[href]")) {
      if (result.length >= limit) break;
      let href;
      try {
        href = new URL(a.getAttribute("href"), document.baseURI).href;
      } catch {
        continue;
      }
      if (!/^https?:/.test(href) || seen.has(href)) continue;
      seen.add(href);
      result.push({ href, text: a.textContent.replace(/\s+/g, " ").trim().slice(0, 200) });
    }
    return result;
  }

  lily.register("dom.extract", extract);
  lily.register("dom.outline", outline);
  lily.register("dom.selection", () => ({ text: selectionText() }));
  lily.register("dom.links", links);
  lily.register("dom.scrollToHeading", ({ id, text }) => {
    let el = id ? document.getElementById(id) : null;
    if (!el && text) el = Array.from(document.querySelectorAll("h1,h2,h3,h4")).find((h) => h.textContent.trim() === text);
    if (!el) return { found: false };
    el.scrollIntoView({ behavior: "smooth", block: "start" });
    return { found: true };
  });
})();
