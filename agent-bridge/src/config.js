// Runtime configuration, sourced from environment variables set by core (or the shell).

function normaliseHost(raw) {
  let host = (raw || "").trim();
  if (!host) return "http://127.0.0.1:11434";
  if (!/^https?:\/\//i.test(host)) host = `http://${host}`;
  const url = new URL(host);
  if (url.hostname === "0.0.0.0") url.hostname = "127.0.0.1";
  if (!url.port && url.protocol === "http:") url.port = "11434";
  return url.origin;
}

function int(value, fallback) {
  const n = Number.parseInt(value ?? "", 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export function loadConfig(env = process.env) {
  return Object.freeze({
    ollamaBaseUrl: normaliseHost(env.OLLAMA_HOST),
    defaultModel: (env.ARC_AGENT_MODEL || "").trim() || null,
    numCtx: int(env.ARC_AGENT_NUM_CTX, 8192),
    // Characters of page/transcript text sent in one prompt before map-reduce kicks in.
    maxContextChars: int(env.ARC_AGENT_MAX_CONTEXT_CHARS, 24000),
    chunkChars: int(env.ARC_AGENT_CHUNK_CHARS, 12000),
    requestTimeoutMs: int(env.ARC_AGENT_TIMEOUT_MS, 300000),
    keepAlive: (env.ARC_AGENT_KEEP_ALIVE || "10m").trim(),
    logLevel: (env.ARC_AGENT_LOG || "info").trim(),
  });
}

export { normaliseHost };
