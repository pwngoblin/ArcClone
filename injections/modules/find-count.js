// How many times the Find bar's text appears in the page (Find in page, FindInPage.swift).
// WebKit's own search selects the matches; this only counts them, case-insensitively, in the
// page's visible text, up to MAX.
(() => {
  "use strict";
  const arc = window.__arc;
  if (!arc || !arc.isMainFrame || window.__arcFindCount) return;
  window.__arcFindCount = true;

  const MAX = 1000;
  const MAX_QUERY = 500;

  arc.register("find.count", ({ query } = {}) => {
    if (typeof query !== "string" || !query || query.length > MAX_QUERY || !document.body) return { count: 0 };
    const needle = query.toLocaleLowerCase();
    const text = document.body.innerText.toLocaleLowerCase();
    let count = 0;
    for (let at = text.indexOf(needle); at !== -1 && count < MAX; at = text.indexOf(needle, at + needle.length)) count += 1;
    return { count };
  });
})();
