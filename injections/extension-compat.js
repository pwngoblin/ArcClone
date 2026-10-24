// Lily compatibility shim for extension content scripts on macOS 14–15.3 (where WebKit has no
// extension controller). Runs first, in the extension's own content world, and provides a minimal
// `chrome` / `browser` object: storage.local (and sync, stored locally), storage.onChanged, and
// clean errors for APIs that need a background context or a desktop app. Talks to native code only
// through the `lilyExtension` handler of this world, with JSON { action, payload } messages.
(() => {
  "use strict";
  if (globalThis.chrome && globalThis.chrome.__lilyCompat) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lilyExtension;
  if (!handler) return;

  let lastError;
  const changeListeners = new Set();

  async function call(action, payload) {
    const raw = await handler.postMessage(JSON.stringify({ action, payload: payload === undefined ? null : payload }));
    const reply = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (!reply || reply.ok !== true) throw new Error((reply && reply.error && reply.error.message) || "Extension call failed");
    return reply.result;
  }

  /// Chrome-style: a callback (with runtime.lastError set on failure) or a promise.
  function settle(promise, callback) {
    if (typeof callback !== "function") return promise;
    promise.then((result) => callback(result), (error) => {
      lastError = { message: String(error && error.message ? error.message : error) };
      try { callback(undefined); } finally { lastError = undefined; }
    });
    return undefined;
  }

  function keyList(keys) {
    if (keys === null || keys === undefined) return null;
    if (typeof keys === "string") return [keys];
    if (Array.isArray(keys)) return keys.map(String);
    return Object.keys(keys);
  }

  function notify(changes) {
    for (const listener of changeListeners) {
      try { listener(changes, "local"); } catch (error) { console.error(error); }
    }
  }

  const storageArea = Object.freeze({
    get(keys, callback) {
      if (typeof keys === "function") { callback = keys; keys = null; }
      const defaults = keys && typeof keys === "object" && !Array.isArray(keys) ? keys : {};
      return settle(call("storage.get", { keys: keyList(keys) }).then((items) => Object.assign({}, defaults, items)), callback);
    },
    set(items, callback) {
      const changes = {};
      for (const key of Object.keys(items || {})) changes[key] = { newValue: items[key] };
      return settle(call("storage.set", { items: items || {} }).then(() => { notify(changes); }), callback);
    },
    remove(keys, callback) {
      const list = keyList(keys) || [];
      const changes = {};
      for (const key of list) changes[key] = { newValue: undefined };
      return settle(call("storage.remove", { keys: list }).then(() => { notify(changes); }), callback);
    },
    clear(callback) {
      return settle(call("storage.clear", {}), callback);
    },
  });

  const listenerSet = (set) => Object.freeze({
    addListener(fn) { if (typeof fn === "function") set.add(fn); },
    removeListener(fn) { set.delete(fn); },
    hasListener(fn) { return set.has(fn); },
  });
  const noListeners = listenerSet(new Set());
  const needsBackground = "This needs macOS 15.4 or later in Lily.";

  const api = Object.freeze({
    __lilyCompat: true,
    runtime: Object.freeze({
      get lastError() { return lastError; },
      sendMessage(...args) {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : undefined;
        return settle(call("runtime.sendMessage", {}), callback);
      },
      sendNativeMessage(application, message, callback) {
        return settle(call("runtime.sendNativeMessage", { application: String(application) }), callback);
      },
      connect() { throw new Error(needsBackground); },
      connectNative(application) {
        call("runtime.connectNative", { application: String(application) }).catch(() => {});
        throw new Error("Lily doesn't connect extensions to desktop apps.");
      },
      getURL() { return ""; },
      onMessage: noListeners,
      onConnect: noListeners,
    }),
    storage: Object.freeze({ local: storageArea, sync: storageArea, onChanged: listenerSet(changeListeners) }),
    i18n: Object.freeze({
      getMessage() { return ""; },
      getUILanguage() { return navigator.language; },
    }),
  });

  Object.defineProperty(globalThis, "chrome", { value: api, configurable: false, writable: false });
  Object.defineProperty(globalThis, "browser", { value: api, configurable: false, writable: false });

  // The extension's content-script CSS for this page, inserted as data.
  call("content.css", {}).then((result) => {
    for (const css of (result && result.css) || []) {
      const style = document.createElement("style");
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
    }
  }).catch(() => {});
})();
