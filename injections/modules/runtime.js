// ArcClone injection runtime.
// Runs first, in the isolated "ArcInjections" content world, in every frame.
// Provides window.__arc: the single bridge every other module uses to talk to core.
//
// Wire protocol (all messages are JSON strings):
//   page -> native   { v: 1, id, kind: "request" | "event", type, payload }
//   native reply     { ok: true, result } | { ok: false, error: { code, message } }
//   native -> page   window.__arc.invoke(name, args) via callAsyncJavaScript
(() => {
  "use strict";
  if (window.__arc) return;

  const PROTOCOL_VERSION = 1;
  const HANDLER = "arc";
  const handlers = new Map();
  let counter = 0;

  function nativeHandler() {
    const mh = window.webkit && window.webkit.messageHandlers;
    return mh && mh[HANDLER] ? mh[HANDLER] : null;
  }

  function nextId() {
    counter += 1;
    return `${Date.now().toString(36)}-${counter.toString(36)}`;
  }

  async function post(kind, type, payload) {
    const handler = nativeHandler();
    if (!handler) throw new Error("ArcClone native bridge unavailable");
    const envelope = { v: PROTOCOL_VERSION, id: nextId(), kind, type, payload: payload ?? null };
    const raw = await handler.postMessage(JSON.stringify(envelope));
    const reply = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (!reply || reply.ok !== true) {
      const err = new Error((reply && reply.error && reply.error.message) || "Native call failed");
      err.code = (reply && reply.error && reply.error.code) || "native_error";
      throw err;
    }
    return reply.result;
  }

  const arc = Object.freeze({
    version: PROTOCOL_VERSION,
    isMainFrame: window.top === window,

    /** Request/response call into core. Resolves with the handler's result. */
    send(type, payload) {
      return post("request", type, payload);
    },

    /** Fire-and-forget event into core. Never throws. */
    emit(type, payload) {
      post("event", type, payload).catch((e) => {
        if (arc.debug) console.debug("[arc] emit failed", type, e);
      });
    },

    /** Expose a function core can call with invoke(name, args). */
    register(name, fn) {
      if (typeof fn !== "function") throw new TypeError(`handler for ${name} must be a function`);
      handlers.set(name, fn);
    },

    /** Called by core through callAsyncJavaScript. Returns a JSON string. */
    async invoke(name, argsJSON) {
      const fn = handlers.get(name);
      if (!fn) {
        return JSON.stringify({ ok: false, error: { code: "unknown_handler", message: `No injection handler '${name}'` } });
      }
      try {
        const args = typeof argsJSON === "string" && argsJSON.length ? JSON.parse(argsJSON) : argsJSON ?? {};
        const result = await fn(args);
        return JSON.stringify({ ok: true, result: result === undefined ? null : result });
      } catch (e) {
        return JSON.stringify({ ok: false, error: { code: e.code || "handler_error", message: String(e && e.message ? e.message : e) } });
      }
    },

    handlers() {
      return Array.from(handlers.keys());
    },

    debug: false,
  });

  Object.defineProperty(window, "__arc", { value: arc, configurable: false, enumerable: false, writable: false });

  arc.register("runtime.ping", () => ({ pong: true, url: location.href, mainFrame: arc.isMainFrame, handlers: arc.handlers() }));

  window.addEventListener("error", (e) => {
    if (!e.filename || !e.filename.startsWith("arc-injection://")) return;
    arc.emit("runtime.error", { message: e.message, source: e.filename, line: e.lineno, column: e.colno });
  });
})();
