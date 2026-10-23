import http from "node:http";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

export async function fakeOllama({ models = [{ name: "llama3.2:latest" }], reply = "Hello from fake", delayMs = 5 } = {}) {
  const calls = [];
  const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const c of req) body += c;
    const json = body ? JSON.parse(body) : null;
    calls.push({ path: req.url, body: json });
    if (req.url === "/api/version") return res.end(JSON.stringify({ version: "0.0.test" }));
    if (req.url === "/api/tags") return res.end(JSON.stringify({ models }));
    if (req.url === "/api/chat") {
      res.writeHead(200, { "content-type": "application/x-ndjson" });
      const text = typeof reply === "function" ? reply(json) : reply;
      for (const word of text.split(/(?<= )/)) {
        if (res.destroyed) return;
        res.write(JSON.stringify({ model: json.model, message: { role: "assistant", content: word }, done: false }) + "\n");
        await new Promise((r) => setTimeout(r, delayMs));
      }
      res.end(JSON.stringify({ model: json.model, done: true, eval_count: 3, prompt_eval_count: 7, total_duration: 1e6, done_reason: "stop" }) + "\n");
      return;
    }
    res.writeHead(404).end();
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${server.address().port}`, calls, close: () => new Promise((r) => server.close(r)) };
}

export function startBridge(env = {}) {
  const main = fileURLToPath(new URL("../src/main.js", import.meta.url));
  const child = spawn(process.execPath, [main], { env: { ...process.env, ARC_AGENT_LOG: "error", ...env }, stdio: ["pipe", "pipe", "inherit"] });
  const pending = new Map();
  const notifications = [];
  const waiters = [];
  let nextId = 1;
  createInterface({ input: child.stdout }).on("line", (line) => {
    const msg = JSON.parse(line);
    if (msg.id != null && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(Object.assign(new Error(msg.error.message), msg.error)) : resolve(msg.result);
    } else if (msg.method) {
      notifications.push(msg);
      for (const w of [...waiters]) if (w.pred(msg)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(msg); }
    }
  });
  return {
    child,
    notifications,
    call(method, params) {
      const id = nextId++;
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    },
    waitFor(pred, timeoutMs = 5000) {
      const hit = notifications.find(pred);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const w = { pred, resolve };
        waiters.push(w);
        setTimeout(() => reject(new Error("timeout waiting for notification")), timeoutMs).unref();
      });
    },
    stop() {
      child.stdin.end();
      return new Promise((r) => child.once("exit", r));
    },
  };
}
