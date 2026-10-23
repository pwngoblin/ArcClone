// Newline-delimited JSON-RPC 2.0 over a pair of streams.
// Requests from core carry an `id`; server -> core notifications (streaming deltas) do not.
import { createInterface } from "node:readline";

export class RpcError extends Error {
  constructor(code, message, data) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

export const ErrorCodes = Object.freeze({
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL_ERROR: -32603,
  OLLAMA_UNAVAILABLE: -32001,
  NO_MODEL: -32002,
  CANCELLED: -32003,
  OLLAMA_ERROR: -32004,
});

export class RpcServer {
  constructor({ input, output, logger }) {
    this.input = input;
    this.output = output;
    this.log = logger;
    this.methods = new Map();
    this.closed = false;
  }

  method(name, fn) {
    this.methods.set(name, fn);
    return this;
  }

  notify(method, params) {
    this.#write({ jsonrpc: "2.0", method, params });
  }

  start() {
    const rl = createInterface({ input: this.input, crlfDelay: Infinity });
    rl.on("line", (line) => {
      if (!line.trim()) return;
      this.#handleLine(line);
    });
    return new Promise((resolve) => {
      rl.on("close", () => {
        this.closed = true;
        resolve();
      });
    });
  }

  #write(message) {
    if (this.closed && this.output.destroyed) return;
    this.output.write(`${JSON.stringify(message)}\n`);
  }

  async #handleLine(line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      this.#write({ jsonrpc: "2.0", id: null, error: { code: ErrorCodes.PARSE_ERROR, message: "Parse error" } });
      return;
    }
    const { id, method, params } = msg ?? {};
    const isRequest = id !== undefined && id !== null;
    if (typeof method !== "string") {
      if (isRequest) this.#write({ jsonrpc: "2.0", id, error: { code: ErrorCodes.INVALID_REQUEST, message: "Invalid request" } });
      return;
    }
    const fn = this.methods.get(method);
    if (!fn) {
      if (isRequest) this.#write({ jsonrpc: "2.0", id, error: { code: ErrorCodes.METHOD_NOT_FOUND, message: `Unknown method ${method}` } });
      return;
    }
    try {
      const result = await fn(params ?? {}, { id });
      if (isRequest) this.#write({ jsonrpc: "2.0", id, result: result === undefined ? null : result });
    } catch (err) {
      const code = Number.isInteger(err?.code) ? err.code : ErrorCodes.INTERNAL_ERROR;
      if (code === ErrorCodes.INTERNAL_ERROR) this.log?.error(`method ${method} failed`, err);
      if (isRequest) this.#write({ jsonrpc: "2.0", id, error: { code, message: err?.message || String(err), data: err?.data } });
    }
  }
}
