// Chrome UI <-> core bridge. Mirrors injections/modules/runtime.js but talks to the
// page-world "chrome" handler. Falls back to an in-memory mock outside WebKit (vite dev).
import { createMockNative } from "./mock-native.js";

const PROTOCOL_VERSION = 1;
const listeners = new Map(); // type -> Set<fn>
let counter = 0;

const handler = typeof window !== "undefined" ? window.webkit?.messageHandlers?.chrome : null;
export const isNative = Boolean(handler);
const mock = isNative ? null : createMockNative(dispatch);

function nextId() {
  counter += 1;
  return `ui-${Date.now().toString(36)}-${counter}`;
}

export class NativeError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/** Request/response call into core. */
export async function request(type, payload = null) {
  const envelope = { v: PROTOCOL_VERSION, id: nextId(), kind: "request", type, payload };
  const raw = isNative ? await handler.postMessage(JSON.stringify(envelope)) : await mock.handle(envelope);
  const reply = typeof raw === "string" ? JSON.parse(raw) : raw;
  if (!reply?.ok) throw new NativeError(reply?.error?.code ?? "native_error", reply?.error?.message ?? `${type} failed`);
  return reply.result;
}

/** Subscribe to native events. Returns an unsubscribe function. */
export function on(type, fn) {
  if (!listeners.has(type)) listeners.set(type, new Set());
  listeners.get(type).add(fn);
  return () => listeners.get(type)?.delete(fn);
}

function dispatch(type, payload) {
  for (const fn of listeners.get(type) ?? []) {
    try {
      fn(payload);
    } catch (e) {
      console.error(`[chrome] listener for ${type} failed`, e);
    }
  }
  for (const fn of listeners.get("*") ?? []) fn({ type, payload });
}

// Core delivers events by calling window.__arcChrome.receive(jsonString).
window.__arcChrome = Object.freeze({
  receive(json) {
    const event = typeof json === "string" ? JSON.parse(json) : json;
    if (event && typeof event.type === "string") dispatch(event.type, event.payload);
  },
});

export function newRequestId() {
  return globalThis.crypto?.randomUUID?.() ?? nextId();
}
