// Minimal Ollama HTTP client with streaming chat support.
import { RpcError, ErrorCodes } from "./rpc.js";

export class OllamaClient {
  constructor({ baseUrl, keepAlive = "10m", timeoutMs = 300000, fetchImpl = globalThis.fetch }) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.keepAlive = keepAlive;
    this.timeoutMs = timeoutMs;
    this.fetch = fetchImpl;
  }

  async #request(path, { method = "GET", body, signal, timeoutMs = 10000 } = {}) {
    const timeout = AbortSignal.timeout(timeoutMs);
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
    let res;
    try {
      res = await this.fetch(`${this.baseUrl}${path}`, {
        method,
        headers: body ? { "content-type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined,
        signal: combined,
      });
    } catch (err) {
      if (signal?.aborted) throw new RpcError(ErrorCodes.CANCELLED, "Request cancelled");
      throw new RpcError(ErrorCodes.OLLAMA_UNAVAILABLE, `Cannot reach Ollama at ${this.baseUrl}: ${err.cause?.code || err.message}`);
    }
    if (!res.ok) {
      let detail = "";
      try {
        detail = (await res.json()).error || "";
      } catch {
        /* body not json */
      }
      throw new RpcError(ErrorCodes.OLLAMA_ERROR, `Ollama ${path} returned ${res.status}${detail ? `: ${detail}` : ""}`);
    }
    return res;
  }

  async version() {
    const res = await this.#request("/api/version");
    return (await res.json()).version;
  }

  async listModels() {
    const res = await this.#request("/api/tags");
    const data = await res.json();
    return (data.models || []).map((m) => ({
      name: m.name,
      size: m.size,
      modifiedAt: m.modified_at,
      family: m.details?.family ?? null,
      parameterSize: m.details?.parameter_size ?? null,
      quantization: m.details?.quantization_level ?? null,
    }));
  }

  /**
   * Streaming chat. Calls onDelta(text) for each content fragment.
   * Resolves with { content, stats } once Ollama reports done.
   */
  async chat({ model, messages, options = {}, signal, onDelta }) {
    const res = await this.#request("/api/chat", {
      method: "POST",
      body: { model, messages, stream: true, keep_alive: this.keepAlive, options },
      signal,
      timeoutMs: this.timeoutMs,
    });
    const decoder = new TextDecoder();
    let buffer = "";
    let content = "";
    let stats = null;
    try {
      for await (const chunk of res.body) {
        buffer += decoder.decode(chunk, { stream: true });
        let nl;
        while ((nl = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, nl).trim();
          buffer = buffer.slice(nl + 1);
          if (!line) continue;
          const evt = JSON.parse(line);
          if (evt.error) throw new RpcError(ErrorCodes.OLLAMA_ERROR, `Ollama: ${evt.error}`);
          const piece = evt.message?.content ?? "";
          if (piece) {
            content += piece;
            onDelta?.(piece);
          }
          if (evt.done) {
            stats = {
              model: evt.model,
              totalDurationMs: evt.total_duration ? Math.round(evt.total_duration / 1e6) : null,
              promptTokens: evt.prompt_eval_count ?? null,
              completionTokens: evt.eval_count ?? null,
              doneReason: evt.done_reason ?? null,
            };
          }
        }
      }
    } catch (err) {
      if (signal?.aborted) throw new RpcError(ErrorCodes.CANCELLED, "Request cancelled");
      throw err;
    }
    return { content, stats };
  }
}
