import { test } from "node:test";
import assert from "node:assert/strict";
import { buildMessages, chunkText } from "../src/prompts.js";
import { normaliseHost } from "../src/config.js";

test("summarize appends task instruction with context", () => {
  const msgs = buildMessages({ task: "summarize", page: { url: "u", title: "t", text: "body" }, maxChars: 100 });
  assert.equal(msgs.length, 2);
  assert.match(msgs[1].content, /^<page>/);
  assert.match(msgs[1].content, /TL;DR/);
});

test("chunkText splits on newlines within bounds", () => {
  const text = Array.from({ length: 100 }, (_, i) => `line number ${i}`).join("\n");
  const chunks = chunkText(text, 200);
  assert.ok(chunks.length > 5);
  assert.ok(chunks.every((c) => c.length <= 200));
  assert.equal(chunks.join("\n").replace(/\s+/g, " "), text.replace(/\s+/g, " "));
});

test("normaliseHost handles Ollama env forms", () => {
  assert.equal(normaliseHost(""), "http://127.0.0.1:11434");
  assert.equal(normaliseHost("0.0.0.0:11434"), "http://127.0.0.1:11434");
  assert.equal(normaliseHost("https://ollama.local"), "https://ollama.local");
  assert.equal(normaliseHost("myhost"), "http://myhost:11434");
});
