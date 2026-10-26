// Lily: inert stand-ins for chrome.* namespaces that WebKit's extension runtime doesn't
// provide, for extensions built for Chrome that use them as soon as their background starts
// (1Password's worker calls chrome.notifications.onClicked.addListener at startup and dies
// without it). Lily adds this file in front of the extension's background when it installs
// the extension; it's part of the audited, pinned copy.
//
// - Only namespaces the manifest asks for and WebKit lacks. A real API is never replaced.
// - Nothing here reaches outside the extension: events never fire, queries return empty or
//   default values, and actions that would need the browser (a download) report that they
//   aren't supported. Two things go to Lily instead, over native-messaging names it answers
//   itself (no other app is involved): notifications, which it shows through macOS
//   (`ExtensionNotifications.swift`) and reports clicks and dismissals back, and a service
//   worker's WebSockets, which WebKit's own freezes (`ExtensionWebSockets.swift`).
// - Plain script (no import/export), so it loads from importScripts, a module import, or an
//   MV2 background scripts list alike.
(() => {
  'use strict';
  const api = globalThis.chrome;
  if (!api || !api.runtime || globalThis.__lilyWorkerCompat) return;
  // WebKit's namespace objects are wrappers it may discard when nothing references them, and a
  // re-created wrapper loses what was added to the old one. Holding every patched object from
  // the global keeps its wrapper, and so its additions, alive.
  const patched = [];
  Object.defineProperty(globalThis, '__lilyWorkerCompat', { value: patched });
  const add = (target, name, value) => {
    try {
      Object.defineProperty(target, name, { value, configurable: true, enumerable: true });
      patched.push(target);
    } catch (error) { /* left as WebKit has it */ }
  };

  const manifest = api.runtime.getManifest();
  const requested = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);
  const unsupported = (name) => new Error(`${name} isn't supported in Lily`);

  // An event and the function that fires it. `onAdd` runs when a listener is first added.
  const emitter = (onAdd) => {
    const listeners = new Set();
    const fire = (...args) => {
      for (const fn of listeners) { try { fn(...args); } catch (error) { queueMicrotask(() => { throw error; }); } }
    };
    return [{
      addListener: (fn) => { if (typeof fn === 'function') { listeners.add(fn); if (onAdd) onAdd(); } },
      removeListener: (fn) => { listeners.delete(fn); },
      hasListener: (fn) => listeners.has(fn),
      hasListeners: () => listeners.size > 0,
    }, fire];
  };
  const event = () => emitter()[0];

  // Chrome's APIs take an optional trailing callback or return a promise.
  const settle = (args, run) => {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    let result;
    let failure = null;
    try { result = run(args); } catch (error) { failure = error; }
    if (callback) {
      queueMicrotask(() => callback(failure ? undefined : result));
      return undefined;
    }
    return failure ? Promise.reject(failure) : Promise.resolve(result);
  };
  // The same for work that answers later (a request to Lily).
  const settleLater = (args, run) => {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const promise = Promise.resolve().then(() => run(args));
    if (callback) {
      promise.then(callback, () => callback(undefined));
      return undefined;
    }
    return promise;
  };
  const returns = (value) => (...args) => settle(args, () => value);
  const refuses = (name) => (...args) => settle(args, () => { throw unsupported(name); });

  const setting = () => ({
    get: returns({ value: false, levelOfControl: 'not_controllable' }),
    set: returns(undefined),
    clear: returns(undefined),
    onChange: event(),
  });
  const settings = (names) => Object.fromEntries(names.map((name) => [name, setting()]));

  const self = () => ({
    id: api.runtime.id,
    name: manifest.name,
    shortName: manifest.short_name || manifest.name,
    version: manifest.version,
    description: manifest.description || '',
    enabled: true,
    mayDisable: true,
    installType: 'normal',
    type: 'extension',
    permissions: manifest.permissions || [],
    hostPermissions: manifest.host_permissions || [],
    offlineEnabled: false,
    optionsUrl: '',
  });

  // Lily's notifications channel. Lily grants native messaging to extensions approved for
  // notifications so this shim can reach it, answers only this name, and refuses every other.
  const channel = 'dev.lily.notifications';
  const runtime = api.runtime;
  const toLily = typeof runtime.sendNativeMessage === 'function' ? runtime.sendNativeMessage.bind(runtime) : null;
  const portToLily = typeof runtime.connectNative === 'function' ? runtime.connectNative.bind(runtime) : null;

  // Diagnostics: with Lily's web developer features on, the background's console goes to Lily's
  // log (debug level, not kept on disk), since an extension's background can't be inspected
  // otherwise. Lines written before Lily answers are kept (up to 200) and sent if it's on.
  if (toLily) {
    const consoleChannel = 'dev.lily.console';
    const describe = (value) => {
      if (value instanceof Error) return value.stack || String(value);
      if (value && typeof value === 'object') { try { return JSON.stringify(value); } catch (error) { return String(value); } }
      return String(value);
    };
    let mode = 'waiting';
    const early = [];
    const send = (line) => { try { toLily(consoleChannel, line).catch(() => {}); } catch (error) { /* not available */ } };
    const note = (level, text) => {
      if (mode === 'off') return;
      const line = { action: 'log', level, text: text.slice(0, 2000) };
      if (mode === 'on') send(line); else if (early.length < 200) early.push(line);
    };
    for (const level of ['error', 'warn', 'info', 'log']) {
      const original = console[level];
      if (typeof original !== 'function') continue;
      console[level] = (...args) => {
        note(level, args.map(describe).join(' '));
        return original.apply(console, args);
      };
    }
    // What the background receives: each message's name and where it came from (never its
    // contents), and the log reports that some extensions' page scripts and popups send their
    // background (1Password's `*-log-event`), which are otherwise invisible. Registered before
    // the extension's own listeners; it never answers, so it changes nothing.
    const nameOf = (message) => String(message && typeof message.name === 'string' ? message.name
      : message && typeof message.type === 'string' ? message.type : typeof message).slice(0, 100);
    const origin = (sender) => {
      try {
        const where = sender && sender.url ? new URL(sender.url).host : 'unknown';
        return `${where} tab ${sender && sender.tab ? sender.tab.id : '-'} frame ${sender ? sender.frameId : '-'}`;
      } catch (error) { return 'unknown'; }
    };
    runtime.onMessage.addListener((message, sender) => {
      const name = nameOf(message);
      note('info', /log-event$/.test(name) ? `[page log] ${describe(message.data)}` : `[Lily] received <${name}> from ${origin(sender)}`);
      return false;
    });
    runtime.onConnect.addListener((port) => note('info', `[Lily] port <${String(port.name).slice(0, 100)}> from ${origin(port.sender)}`));
    // How the extension's own listeners answer: each reply's kind (Success, Error, undefined; never
    // its contents) and delay, or that a listener promised a reply and sent none within 10 s.
    const kindOf = (value) => (value === undefined ? 'undefined' : value && typeof value.type === 'string'
      ? value.type + (value.type === 'Error' && value.message ? ` (${String(value.message).slice(0, 200)})` : '') : typeof value);
    for (const target of [runtime, globalThis.browser && globalThis.browser.runtime].filter(Boolean)) {
      const event = target.onMessage;
      if (!event || typeof event.addListener !== 'function') continue;
      const { addListener, removeListener, hasListener } = event;
      const wrappers = new WeakMap();
      const wrap = (listener) => {
        if (typeof listener !== 'function') return listener;
        if (!wrappers.has(listener)) {
          wrappers.set(listener, function (message, sender, sendResponse) {
            if (mode === 'off') return listener.call(this, message, sender, sendResponse);
            const name = nameOf(message);
            const started = Date.now();
            let replied = false;
            const respond = (value) => {
              replied = true;
              note('info', `[Lily] reply <${name}>: ${kindOf(value)} after ${Date.now() - started} ms`);
              return sendResponse(value);
            };
            const result = listener.call(this, message, sender, respond);
            if (result === true) {
              setTimeout(() => { if (!replied) note('warn', `[Lily] no reply to <${name}> after 10 s`); }, 10000);
            } else if (result && typeof result.then === 'function') {
              result.then((value) => note('info', `[Lily] reply <${name}> (promise): ${kindOf(value)} after ${Date.now() - started} ms`),
                (error) => note('warn', `[Lily] reply <${name}> (promise) failed: ${describe(error)}`));
            }
            return result;
          });
        }
        return wrappers.get(listener);
      };
      add(event, 'addListener', function (listener, ...rest) { return addListener.call(this, wrap(listener), ...rest); });
      add(event, 'removeListener', function (listener) { return removeListener.call(this, wrappers.get(listener) || listener); });
      if (typeof hasListener === 'function') add(event, 'hasListener', function (listener) { return hasListener.call(this, wrappers.get(listener) || listener); });
    }
    try {
      toLily(consoleChannel, { action: 'enabled' }).then((on) => {
        mode = on === true ? 'on' : 'off';
        if (mode === 'on') early.forEach(send);
        early.length = 0;
      }, () => { mode = 'off'; early.length = 0; });
    } catch (error) { mode = 'off'; }
  }

  // WebSocket in a service worker. WebKit runs an extension's worker on its process's main thread,
  // and `new WebSocket('wss://…')` there waits on that same thread: the background freezes for
  // good (1Password's sync connection after sign-in). This stand-in connects through Lily
  // (`ExtensionWebSockets.swift`), one port per socket, and behaves as WebSocket does: events
  // `open`, `message`, `error`, `close` and their `on…` properties, `send`, `close`. Without the
  // channel a socket fails as an unreachable server would, which beats freezing.
  if (typeof WorkerGlobalScope === 'function' && globalThis instanceof WorkerGlobalScope && typeof globalThis.WebSocket === 'function') {
    const socketChannel = 'dev.lily.websocket';
    const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
    const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
    const toBase64 = (bytes) => {
      let text = '';
      for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return btoa(text);
    };
    class LilyWebSocket extends EventTarget {
      #port = null;
      #state = states.CONNECTING;
      #url;
      #protocol = '';
      #binaryType = 'blob';
      #queue = Promise.resolve();
      #opening = null;
      constructor(url, protocols) {
        super();
        let parsed;
        try { parsed = new URL(url, globalThis.location && globalThis.location.href); } catch (error) { throw new DOMException(`Invalid URL '${url}'`, 'SyntaxError'); }
        if (parsed.protocol === 'http:') parsed.protocol = 'ws:'; else if (parsed.protocol === 'https:') parsed.protocol = 'wss:';
        if ((parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') || parsed.hash) throw new DOMException(`Invalid URL '${url}'`, 'SyntaxError');
        this.#url = parsed.href;
        const list = protocols === undefined ? [] : (Array.isArray(protocols) ? protocols : [protocols]).map(String);
        for (const [name, value] of Object.entries(states)) Object.defineProperty(this, name, { value });
        let port = null;
        try { port = portToLily ? portToLily(socketChannel) : null; } catch (error) { port = null; }
        if (!port) { setTimeout(() => this.#closed({ code: 1006, reason: '', wasClean: false }, true), 0); return; }
        this.#port = port;
        port.onMessage.addListener((message) => this.#received(message));
        port.onDisconnect.addListener(() => { if (this.#state !== states.CLOSED) this.#closed({ code: 1006, reason: '', wasClean: false }, true); });
        this.#opening = { action: 'open', url: this.#url, protocols: list };
      }
      get url() { return this.#url; }
      get readyState() { return this.#state; }
      get protocol() { return this.#protocol; }
      get extensions() { return ''; }
      get bufferedAmount() { return 0; }
      get binaryType() { return this.#binaryType; }
      set binaryType(value) { if (value === 'blob' || value === 'arraybuffer') this.#binaryType = value; }
      send(data) {
        if (this.#state === states.CONNECTING) throw new DOMException('WebSocket is not open', 'InvalidStateError');
        if (this.#state !== states.OPEN) return;
        // Blobs are read asynchronously, so every send queues behind the one before to keep order.
        const payload = typeof data === 'string' ? { text: data }
          : data instanceof Blob ? data.arrayBuffer().then((buffer) => ({ binary: toBase64(new Uint8Array(buffer)) }))
          : { binary: toBase64(ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(data)) };
        this.#queue = this.#queue.then(() => payload).then((message) => {
          if (this.#state === states.OPEN) this.#port.postMessage({ action: 'send', ...message });
        }, () => {});
      }
      close(code, reason) {
        if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) throw new DOMException('Invalid close code', 'InvalidAccessError');
        if (this.#state === states.CLOSING || this.#state === states.CLOSED) return;
        this.#state = states.CLOSING;
        try { this.#port.postMessage({ action: 'close', code, reason: reason === undefined ? undefined : String(reason) }); } catch (error) { /* already gone */ }
      }
      #received(message) {
        if (!message || typeof message.type !== 'string' || this.#state === states.CLOSED) return;
        if (message.type === 'ready' && this.#opening) {
          // Lily can take messages on this port from now on.
          this.#port.postMessage(this.#opening);
          this.#opening = null;
        } else if (message.type === 'open' && this.#state === states.CONNECTING) {
          this.#state = states.OPEN;
          this.#protocol = String(message.protocol || '');
          this.#fire(new Event('open'));
        } else if (message.type === 'message') {
          let data;
          if (typeof message.text === 'string') data = message.text;
          else if (typeof message.binary === 'string') {
            const bytes = fromBase64(message.binary);
            data = this.#binaryType === 'arraybuffer' ? bytes.buffer : new Blob([bytes]);
          } else return;
          this.#fire(new MessageEvent('message', { data, origin: new URL(this.#url).origin }));
        } else if (message.type === 'error') {
          this.#fire(new Event('error'));
        } else if (message.type === 'close') {
          this.#closed({ code: Number(message.code) || 1006, reason: String(message.reason || ''), wasClean: message.wasClean === true }, false);
        }
      }
      #closed(detail, withError) {
        if (this.#state === states.CLOSED) return;
        this.#state = states.CLOSED;
        if (withError) this.#fire(new Event('error'));
        this.#fire(new CloseEvent('close', detail));
        try { this.#port && this.#port.disconnect(); } catch (error) { /* already gone */ }
        this.#port = null;
      }
      #fire(event) {
        const handler = this['on' + event.type];
        this.dispatchEvent(event);
        if (typeof handler === 'function') { try { handler.call(this, event); } catch (error) { queueMicrotask(() => { throw error; }); } }
      }
    }
    for (const name of ['onopen', 'onmessage', 'onerror', 'onclose']) {
      Object.defineProperty(LilyWebSocket.prototype, name, { value: null, writable: true, configurable: true, enumerable: true });
    }
    for (const [name, value] of Object.entries(states)) Object.defineProperty(LilyWebSocket, name, { value });
    Object.defineProperty(globalThis, 'WebSocket', { value: LilyWebSocket, writable: true, configurable: true });
  }

  // chrome.notifications through Lily: create, update and clear are requests; clicks, button
  // clicks and dismissals come back over a port while the extension has notifications showing,
  // and those that happen while the background is asleep are collected when it next listens.
  const lilyNotifications = () => {
    let port = null;
    let collected = false;
    const ask = (request) => toLily(channel, request);
    const collect = () => {
      if (collected) return;
      collected = true;
      queueMicrotask(() => ask({ action: 'events' }).then((list) => { if (Array.isArray(list)) list.forEach(deliver); }, () => {}));
    };
    const [onClicked, clicked] = emitter(collect);
    const [onButtonClicked, buttonClicked] = emitter(collect);
    const [onClosed, closed] = emitter(collect);
    const deliver = (message) => {
      if (!message || typeof message.id !== 'string') return;
      if (message.type === 'clicked') clicked(message.id);
      else if (message.type === 'buttonClicked' && Number.isInteger(message.buttonIndex)) buttonClicked(message.id, message.buttonIndex);
      else if (message.type === 'closed') closed(message.id, message.byUser === true);
    };
    const listen = () => {
      if (port || !portToLily) return;
      try {
        port = portToLily(channel);
        port.onMessage.addListener(deliver);
        port.onDisconnect.addListener(() => { port = null; });
      } catch (error) { port = null; }
    };
    // create(id?, options) and update(id, options): Chrome's id is optional on create.
    const send = (action) => (...args) => settleLater(args, ([first, second]) => {
      const [id, options] = typeof first === 'string' ? [first, second] : [undefined, first];
      return ask({ action, id, options }).then((answer) => {
        if (action === 'create') { listen(); return answer && answer.id; }
        return answer && answer.done === true;
      });
    });
    return {
      create: send('create'),
      update: send('update'),
      clear: (...args) => settleLater(args, ([id]) => ask({ action: 'clear', id }).then((answer) => answer && answer.done === true)),
      getAll: (...args) => settleLater(args, () => ask({ action: 'getAll' }).then((answer) =>
        Object.fromEntries(((answer && answer.ids) || []).map((id) => [id, true])))),
      getPermissionLevel: (...args) => settleLater(args, () => ask({ action: 'getPermissionLevel' }).then((answer) =>
        (answer && answer.level) || 'denied')),
      onClicked,
      onClosed,
      onButtonClicked,
      onPermissionLevelChanged: event(),
      onShowSettings: event(),
      TemplateType: { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' },
      PermissionLevel: { GRANTED: 'granted', DENIED: 'denied' },
    };
  };

  const stubs = {
    notifications: () => {
      if (toLily) return lilyNotifications();
      let counter = 0;
      return {
        // Accepted so callers continue, but nothing is shown.
        create: (...args) => settle(args, ([id]) => (typeof id === 'string' && id) || `lily-${++counter}`),
        update: returns(false),
        clear: returns(false),
        getAll: returns({}),
        getPermissionLevel: returns('denied'),
        onClicked: event(),
        onClosed: event(),
        onButtonClicked: event(),
        onPermissionLevelChanged: event(),
        onShowSettings: event(),
        TemplateType: { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' },
        PermissionLevel: { GRANTED: 'granted', DENIED: 'denied' },
      };
    },
    privacy: () => ({
      services: settings(['alternateErrorPagesEnabled', 'autofillAddressEnabled', 'autofillCreditCardEnabled', 'autofillEnabled',
        'passwordSavingEnabled', 'safeBrowsingEnabled', 'safeBrowsingExtendedReportingEnabled', 'searchSuggestEnabled',
        'spellingServiceEnabled', 'translationServiceEnabled']),
      network: settings(['networkPredictionEnabled', 'webRTCIPHandlingPolicy']),
      websites: settings(['doNotTrackEnabled', 'hyperlinkAuditingEnabled', 'protectedContentEnabled', 'referrersEnabled',
        'thirdPartyCookiesAllowed']),
    }),
    management: () => ({
      getSelf: returns(self()),
      getAll: returns([self()]),
      get: (...args) => settle(args, ([id]) => { if (id === api.runtime.id) return self(); throw unsupported('management.get'); }),
      getPermissionWarningsById: returns([]),
      getPermissionWarningsByManifest: returns([]),
      setEnabled: refuses('management.setEnabled'),
      uninstall: refuses('management.uninstall'),
      uninstallSelf: refuses('management.uninstallSelf'),
      launchApp: refuses('management.launchApp'),
      onEnabled: event(),
      onDisabled: event(),
      onInstalled: event(),
      onUninstalled: event(),
    }),
    idle: () => ({
      queryState: returns('active'),
      setDetectionInterval: () => undefined,
      getAutoLockDelay: returns(0),
      onStateChanged: event(),
      IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' },
    }),
    downloads: () => ({
      download: refuses('downloads.download'),
      search: returns([]),
      pause: returns(undefined),
      resume: returns(undefined),
      cancel: returns(undefined),
      erase: returns([]),
      open: refuses('downloads.open'),
      show: refuses('downloads.show'),
      showDefaultFolder: () => undefined,
      getFileIcon: refuses('downloads.getFileIcon'),
      setUiOptions: returns(undefined),
      onCreated: event(),
      onChanged: event(),
      onErased: event(),
      onDeterminingFilename: event(),
    }),
  };

  // `storage.managed` holds enterprise policy, which Lily has none of: always empty, read-only.
  const managedStorage = () => ({
    get: returns({}),
    getBytesInUse: returns(0),
    set: refuses('storage.managed.set'),
    remove: refuses('storage.managed.remove'),
    clear: refuses('storage.managed.clear'),
    onChanged: event(),
  });

  // Members Chrome has on namespaces WebKit does provide, but WebKit doesn't implement: events
  // that never fire, so registering a listener doesn't throw, and the empty policy store.
  const listeners = (names) => Object.fromEntries(names.map((name) => [name, event]));
  const members = {
    webNavigation: listeners(['onCreatedNavigationTarget', 'onTabReplaced', 'onHistoryStateUpdated', 'onReferenceFragmentUpdated']),
    webRequest: listeners(['onAuthRequired', 'onActionIgnored']),
    tabs: listeners(['onReplaced', 'onZoomChange', 'onHighlighted', 'onDetached', 'onAttached']),
    windows: listeners(['onBoundsChanged']),
    runtime: listeners(['onUpdateAvailable', 'onRestartRequired', 'onSuspend', 'onSuspendCanceled', 'onUserScriptMessage', 'onUserScriptConnect']),
    storage: { managed: managedStorage },
  };
  for (const [name, missing] of Object.entries(members)) {
    // `chrome` and `browser` are separate objects in WebKit, and extensions use either.
    for (const target of [api[name], globalThis.browser && globalThis.browser[name]].filter(Boolean)) {
      for (const [member, make] of Object.entries(missing)) {
        if (target[member] === undefined) add(target, member, Object.freeze(make()));
      }
    }
  }

  for (const [name, make] of Object.entries(stubs)) {
    if (!requested.has(name) || api[name] !== undefined) continue;
    const value = Object.freeze(make());
    for (const target of [api, globalThis.browser].filter(Boolean)) {
      if (target[name] === undefined) add(target, name, value);
    }
  }
})();
