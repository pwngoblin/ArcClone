// Lily procedural element hiding: the filter-list rules WebKit's content blockers can't
// express, such as `div.post:has-text(Sponsored):upward(2)`, and `:style()` rules that undo what a
// hidden cookie wall left behind (e.g. `body { overflow: hidden }`). Native code sends this site's filters
// (looked up from the frame's real origin) as plain data: selectors, text and numbers. Nothing in
// them is ever run as code. Runs in the isolated injection world.
(() => {
  "use strict";
  const lily = window.__lily;
  if (!lily || !lily.isMainFrame || window.__lilyCosmeticFilter) return;
  window.__lilyCosmeticFilter = true;

  const MAX_MATCHES = 500; // per filter per pass, so a page can't make a pass arbitrarily slow
  let filters = [];
  let observer = null;
  let scheduled = false;
  const hidden = new WeakSet();
  const styled = new WeakSet();

  function textMatcher(arg) {
    const regex = /^\/(.+)\/([imsu]*)$/.exec(arg);
    if (regex) {
      try {
        const re = new RegExp(regex[1], regex[2]);
        return (text) => re.test(text);
      } catch { return null; }
    }
    return (text) => text.includes(arg);
  }

  /// "overflow: auto; position: static" → [["overflow", "auto"], ["position", "static"]].
  /// Native code has already limited properties and values to layout keywords and lengths.
  function declarations(style) {
    if (typeof style !== "string") return null;
    const pairs = style.split(";").map((part) => {
      const colon = part.indexOf(":");
      return colon < 0 ? null : [part.slice(0, colon).trim(), part.slice(colon + 1).trim()];
    }).filter((pair) => pair && pair[0] && pair[1]);
    return pairs.length ? pairs : null;
  }

  /// [{ selector, steps: [{ type, arg }], style? }] → functions from a list of elements to a list of elements.
  function prepare(list) {
    const prepared = [];
    for (const filter of Array.isArray(list) ? list : []) {
      if (typeof filter?.selector !== "string" || !Array.isArray(filter.steps)) continue;
      const steps = [];
      let valid = true;
      for (const step of filter.steps) {
        const arg = typeof step?.arg === "string" ? step.arg : "";
        if (step?.type === "has-text") {
          const matches = textMatcher(arg);
          if (!matches) { valid = false; break; }
          steps.push((nodes) => nodes.filter((node) => matches(node.textContent || "")));
        } else if (step?.type === "min-text-length") {
          const min = Number(arg);
          steps.push((nodes) => nodes.filter((node) => (node.textContent || "").length >= min));
        } else if (step?.type === "upward") {
          const levels = /^\d+$/.test(arg) ? Number(arg) : 0;
          steps.push((nodes) => nodes.map((node) => {
            if (!levels) {
              try { return node.parentElement?.closest(arg) ?? null; } catch { return null; }
            }
            let current = node;
            for (let i = 0; i < levels && current; i += 1) current = current.parentElement;
            return current;
          }).filter(Boolean));
        } else {
          valid = false;
          break;
        }
      }
      const style = filter.style === undefined || filter.style === null ? null : declarations(filter.style);
      if (filter.style && !style) valid = false;
      if (valid) prepared.push({ selector: filter.selector, steps, style });
    }
    return prepared;
  }

  function hide(node) {
    if (hidden.has(node) || node === document.documentElement || node === document.body) return;
    hidden.add(node);
    node.style.setProperty("display", "none", "important");
  }

  function restyle(node, style) {
    if (styled.has(node)) return;
    styled.add(node);
    for (const [property, value] of style) node.style.setProperty(property, value, "important");
  }

  function apply() {
    scheduled = false;
    for (const filter of filters) {
      let nodes;
      try {
        nodes = Array.from(document.querySelectorAll(filter.selector)).slice(0, MAX_MATCHES);
      } catch { continue; }
      for (const step of filter.steps) {
        if (!nodes.length) break;
        nodes = step(nodes);
      }
      if (filter.style) nodes.forEach((node) => restyle(node, filter.style));
      else nodes.forEach(hide);
    }
  }

  /// Pages keep adding content (feeds, infinite scroll); re-check at most every 250 ms.
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    setTimeout(apply, 250);
  }

  async function start() {
    let reply;
    try { reply = await lily.send("adblock.procedural", {}); } catch { return; }
    filters = prepare(reply?.filters);
    if (!filters.length) return;
    apply();
    observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, { childList: true, subtree: true });
  }

  start();
})();
