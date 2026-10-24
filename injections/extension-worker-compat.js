// Lily: inert stand-ins for chrome.* namespaces that WebKit's extension runtime doesn't
// provide, for extensions built for Chrome that use them as soon as their background starts
// (1Password's worker calls chrome.notifications.onClicked.addListener at startup and dies
// without it). Lily adds this file in front of the extension's background when it installs
// the extension; it's part of the audited, pinned copy.
//
// - Only namespaces the manifest asks for and WebKit lacks. A real API is never replaced.
// - Nothing here reaches outside the extension: events never fire, queries return empty or
//   default values, and actions that would need the browser (a download, a notification) report
//   that they aren't supported.
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

  const event = () => {
    const listeners = new Set();
    return {
      addListener: (fn) => { if (typeof fn === 'function') listeners.add(fn); },
      removeListener: (fn) => { listeners.delete(fn); },
      hasListener: (fn) => listeners.has(fn),
      hasListeners: () => listeners.size > 0,
    };
  };

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

  const stubs = {
    notifications: () => {
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
