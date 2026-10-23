#!/usr/bin/env node
// ArcClone agent bridge entry point.
// Launched and supervised by core; speaks NDJSON JSON-RPC 2.0 on stdin/stdout.
import { loadConfig } from "./config.js";
import { createLogger } from "./log.js";
import { RpcServer } from "./rpc.js";
import { OllamaClient } from "./ollama.js";
import { ContextStore } from "./context-store.js";
import { Agent } from "./agent.js";

export function createBridge({ input = process.stdin, output = process.stdout, env = process.env, fetchImpl } = {}) {
  const config = loadConfig(env);
  const log = createLogger(config.logLevel);
  const server = new RpcServer({ input, output, logger: log });
  const ollama = new OllamaClient({ baseUrl: config.ollamaBaseUrl, keepAlive: config.keepAlive, timeoutMs: config.requestTimeoutMs, fetchImpl });
  const context = new ContextStore();
  const agent = new Agent({ config, ollama, context, logger: log, notify: (m, p) => server.notify(m, p) });
  const startedAt = Date.now();

  server
    .method("bridge.health", async () => {
      let ollamaStatus;
      try {
        const [version, models] = await Promise.all([ollama.version(), agent.models({ refresh: true })]);
        ollamaStatus = { reachable: true, version, modelCount: models.length };
      } catch (err) {
        ollamaStatus = { reachable: false, error: err.message };
      }
      return {
        bridge: { pid: process.pid, uptimeMs: Date.now() - startedAt, node: process.version, running: agent.running.size },
        ollama: { baseUrl: config.ollamaBaseUrl, ...ollamaStatus },
        defaultModel: config.defaultModel,
        context: context.stats(),
      };
    })
    .method("models.list", async (p) => ({ models: await agent.models({ refresh: Boolean(p.refresh) }) }))
    .method("agent.run", (p) => agent.start(p))
    .method("agent.cancel", (p) => agent.cancel(p))
    .method("events.ingest", (p) => context.ingest(p))
    .method("context.get", (p) => context.snapshot(p.tabId))
    .method("bridge.shutdown", () => {
      setImmediate(() => shutdown(0));
      return { ok: true };
    });

  function shutdown(code) {
    agent.cancelAll();
    log.info("shutting down");
    process.exit(code);
  }

  return { server, agent, context, config, log, shutdown };
}

const isEntry = import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("/agent-bridge/src/main.js");
if (isEntry) {
  const { server, config, log, shutdown } = createBridge();
  log.info(`ready (ollama ${config.ollamaBaseUrl}, model ${config.defaultModel || "auto"})`);
  server.notify("bridge.ready", { pid: process.pid, ollamaBaseUrl: config.ollamaBaseUrl });
  process.on("SIGTERM", () => shutdown(0));
  process.on("SIGINT", () => shutdown(0));
  process.stdout.on("error", () => shutdown(0)); // core went away
  server.start().then(() => shutdown(0)); // stdin closed: parent exited
}
