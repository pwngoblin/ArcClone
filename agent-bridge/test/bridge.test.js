import { test } from "node:test";
import assert from "node:assert/strict";
import { fakeOllama, startBridge } from "./helpers.js";

test("health reports ollama status and models", async () => {
  const ollama = await fakeOllama();
  const bridge = startBridge({ OLLAMA_HOST: ollama.url });
  try {
    const ready = await bridge.waitFor((n) => n.method === "bridge.ready");
    assert.ok(ready.params.pid);
    const health = await bridge.call("bridge.health");
    assert.equal(health.ollama.reachable, true);
    assert.equal(health.ollama.version, "0.0.test");
    assert.equal(health.ollama.modelCount, 1);
    const { models } = await bridge.call("models.list");
    assert.equal(models[0].name, "llama3.2:latest");
  } finally {
    await bridge.stop();
    await ollama.close();
  }
});

test("health reports unreachable ollama without failing", async () => {
  const bridge = startBridge({ OLLAMA_HOST: "http://127.0.0.1:1" });
  try {
    const health = await bridge.call("bridge.health");
    assert.equal(health.ollama.reachable, false);
    assert.match(health.ollama.error, /Cannot reach Ollama/);
  } finally {
    await bridge.stop();
  }
});

test("chat streams deltas then done, with page context attached", async () => {
  const ollama = await fakeOllama({ reply: "The page is about testing." });
  const bridge = startBridge({ OLLAMA_HOST: ollama.url });
  try {
    const { requestId, model } = await bridge.call("agent.run", {
      task: "chat",
      tabId: "t1",
      messages: [{ role: "user", content: "What is this?" }],
      page: { url: "https://example.com", title: "Example", text: "Testing content" },
    });
    assert.equal(model, "llama3.2:latest");
    const done = await bridge.waitFor((n) => n.method === "agent.done" && n.params.requestId === requestId);
    const deltas = bridge.notifications.filter((n) => n.method === "agent.delta" && n.params.requestId === requestId).map((n) => n.params.delta);
    assert.equal(deltas.join(""), "The page is about testing.");
    assert.equal(done.params.content, "The page is about testing.");
    assert.equal(done.params.stats.completionTokens, 3);
    const chat = ollama.calls.find((c) => c.path === "/api/chat");
    const userTurn = chat.body.messages.at(-1).content;
    assert.match(userTurn, /<page>/);
    assert.match(userTurn, /Testing content/);
    assert.match(userTurn, /What is this\?$/);
    assert.equal(chat.body.messages[0].role, "system");
  } finally {
    await bridge.stop();
    await ollama.close();
  }
});

test("missing models produce a NO_MODEL error", async () => {
  const ollama = await fakeOllama({ models: [] });
  const bridge = startBridge({ OLLAMA_HOST: ollama.url });
  try {
    await assert.rejects(bridge.call("agent.run", { task: "summarize", page: { text: "x" } }), (e) => e.code === -32002 && /ollama pull/.test(e.message));
  } finally {
    await bridge.stop();
    await ollama.close();
  }
});

test("cancel aborts a running request", async () => {
  const ollama = await fakeOllama({ reply: "word ".repeat(400), delayMs: 10 });
  const bridge = startBridge({ OLLAMA_HOST: ollama.url });
  try {
    const { requestId } = await bridge.call("agent.run", { task: "chat", messages: [{ role: "user", content: "go" }] });
    await bridge.waitFor((n) => n.method === "agent.delta" && n.params.requestId === requestId);
    assert.deepEqual(await bridge.call("agent.cancel", { requestId }), { cancelled: true });
    const err = await bridge.waitFor((n) => n.method === "agent.error" && n.params.requestId === requestId);
    assert.equal(err.params.code, -32003);
  } finally {
    await bridge.stop();
    await ollama.close();
  }
});

test("long transcripts are condensed in chunks before the final answer", async () => {
  const ollama = await fakeOllama({ reply: (body) => (body.messages[1].content.includes("<excerpt") ? "- note " : "Final summary") });
  const bridge = startBridge({ OLLAMA_HOST: ollama.url, ARC_AGENT_MAX_CONTEXT_CHARS: "2000", ARC_AGENT_CHUNK_CHARS: "1000" });
  try {
    const text = Array.from({ length: 200 }, (_, i) => `[0:${String(i).padStart(2, "0")}] line ${i}`).join("\n");
    const { requestId } = await bridge.call("agent.run", { task: "summarize-video", transcript: { videoId: "abc", title: "Vid", text } });
    const done = await bridge.waitFor((n) => n.method === "agent.done" && n.params.requestId === requestId);
    assert.equal(done.params.content, "Final summary");
    const chunkCalls = ollama.calls.filter((c) => c.path === "/api/chat" && c.body.messages[1].content.includes("<excerpt"));
    assert.ok(chunkCalls.length >= 3, `expected several chunk calls, got ${chunkCalls.length}`);
    const statuses = bridge.notifications.filter((n) => n.method === "agent.status" && n.params.phase === "reading");
    assert.equal(statuses.length, chunkCalls.length);
  } finally {
    await bridge.stop();
    await ollama.close();
  }
});

test("events are ingested into per-tab context", async () => {
  const bridge = startBridge({ OLLAMA_HOST: "http://127.0.0.1:1" });
  try {
    await bridge.call("events.ingest", { tabId: "7", type: "page.didChange", payload: { url: "https://a.test/", title: "A" } });
    await bridge.call("events.ingest", { tabId: "7", type: "selection.changed", payload: { text: "hello", url: "https://a.test/" } });
    const ctx = await bridge.call("context.get", { tabId: "7" });
    assert.equal(ctx.page.title, "A");
    assert.equal(ctx.selection.text, "hello");
    assert.equal(ctx.recentHistory.length, 1);
    await bridge.call("events.ingest", { tabId: "7", type: "tab.closed" });
    assert.equal((await bridge.call("context.get", { tabId: "7" })).page, null);
  } finally {
    await bridge.stop();
  }
});

test("unknown methods and bad params are rejected", async () => {
  const bridge = startBridge({ OLLAMA_HOST: "http://127.0.0.1:1" });
  try {
    await assert.rejects(bridge.call("nope"), (e) => e.code === -32601);
    await assert.rejects(bridge.call("agent.run", { task: "bogus" }), (e) => e.code === -32602);
  } finally {
    await bridge.stop();
  }
});
