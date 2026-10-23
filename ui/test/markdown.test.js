import { test } from "node:test";
import assert from "node:assert/strict";
import { renderMarkdown, escapeHTML, parseTimestamp } from "../src/lib/markdown.js";

test("escapes raw HTML from model output", () => {
  const html = renderMarkdown('<img src=x onerror="alert(1)"> <script>alert(2)</script>');
  assert.ok(!html.includes("<img"));
  assert.ok(!html.includes("<script"));
  assert.ok(html.includes("&lt;script&gt;"));
});

test("only http(s) links become anchors", () => {
  assert.match(renderMarkdown("[ok](https://example.com)"), /<a href="https:\/\/example.com"/);
  assert.doesNotMatch(renderMarkdown("[x](javascript:alert(1))"), /<a /);
});

test("attribute breakout in link targets is neutralised", () => {
  const html = renderMarkdown('[x](https://e.com/"onmouseover="alert(1))');
  assert.doesNotMatch(html, /"onmouseover="/);
});

test("renders lists, code and timestamps", () => {
  const html = renderMarkdown("**TL;DR** done\n\n- one [1:05]\n- `two`\n\n```\n<b>raw</b>\n```");
  assert.match(html, /<strong>TL;DR<\/strong>/);
  assert.match(html, /<ul>\n<li>one <button class="ts" data-seek="65">1:05<\/button><\/li>/);
  assert.match(html, /<code>two<\/code>/);
  assert.match(html, /<pre><code>&lt;b&gt;raw&lt;\/b&gt;<\/code><\/pre>/);
});

test("helpers", () => {
  assert.equal(escapeHTML(`<"&'>`), "&lt;&quot;&amp;&#39;&gt;");
  assert.equal(parseTimestamp("1:02:03"), 3723);
});
