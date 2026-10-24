# Browser extensions in ArcClone

Most extensions ship as compiled packages from a store, not as source you can review. ArcClone's approach, in order of preference:

1. **Build it in.** Write a small first-party module (Swift, plus an injected script if the page has to be touched).
2. **Audit and pin.** If a third-party extension is truly needed, add it as a reviewed, pinned copy that never changes on its own.
3. **Isolate at runtime.** Whatever runs, it can't reach ArcClone's native bridge, and it can't load code that wasn't reviewed.

## 1. Prefer first-party modules

Many popular extensions duplicate features ArcClone already has:

| Instead of… | Use |
|---|---|
| An ad or tracker blocker | Settings → Privacy: the built-in list plus EasyList, EasyPrivacy, uBlock filters, Peter Lowe's list or AdGuard Annoyances (`core/Sources/ArcCloneCore/AdBlock/`) |
| A YouTube ad skipper | Built in (`injections/modules/youtube-adblock.js`) |
| A dark-mode extension | Dark mode for websites, ⌥⌘D (`injections/modules/dark-mode.js`) |
| An HTTPS-upgrade extension | HTTPS-First (Settings → Privacy) |
| A summarizer or AI sidebar | The assistant, ⌘E (local Ollama) |

For anything else, add a module. The pattern every existing module follows:

**Page side: `injections/modules/<name>.js`**
- Wrap the module in an IIFE that exits if `window.__arc` is missing or the module already ran (see `cosmetic-filter.js`).
- Talk to native code only through `window.__arc`:
  - `arc.send(type, payload)` makes a request.
  - `arc.emit(type, payload)` fires an event.
  - `arc.register(name, fn)` lets native code call into the page.
- Treat everything native code sends as data, never as code. No `eval`, `new Function`, string timers, `innerHTML` or `setInterval`; `scripts/security-lint.sh` rejects them.
- React to page changes with a `MutationObserver` and debounce with `setTimeout`, or let native code call you (`page.recheck`). Never poll.

**Manifest: `injections/manifest.json`**
- Add `{ "id", "file", "injectionTime", "mainFrameOnly", "matches" }`. Limit `matches` to the hosts you need (for example `["youtube.com", "*.youtube.com"]`); `InjectionManifest.validate()` enforces the grammar.
- All modules run in the isolated `ArcInjections` content world. Page scripts can't see or modify them.

**Native side: `core/Sources/ArcCloneCore/Handlers/`**
- Register a route with `router.on("<module>.<message>", from: [.page], as: YourPayload.self) { ctx, payload in … }` in `PageHandlers.swift`.
- Decode the payload into a fixed `Decodable` schema with length limits (`PagePayloads.swift`). Unknown or oversized messages are refused before they're parsed.
- Use the origin from `ctx.source`, which WebKit sets from the frame's real security origin, never a URL the page reports. `PagePayload.sameOrigin` rejects mismatches.
- Call into the page with `tab.callInjection(name, args)`. Arguments travel as JSON through `callAsyncJavaScript`'s argument dictionary; JavaScript is never built from strings.

**Tests:**
- Unit tests for the payload schema, under `core/Tests/ArcCloneCoreTests/`.
- A check in `App/SelfTest.swift` that loads a fixture page and confirms the module works end to end (see "procedural filters").
- `make check` runs the lint and the tests. CI runs it too.

## 2. Audit and pin a third-party extension

Settings → Extensions → **Add Extension…** accepts an unpacked folder (with `manifest.json`), a `.zip`, or a Chrome Web Store `.crx`.

**Getting a `.crx` for a store extension.** Take the 32-letter ID from the store URL and download:

```
https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0&acceptformat=crx2,crx3&x=id%3D<ID>%26uc
```

**What happens when you add it** (`ExtensionPackage.swift`, `ExtensionAudit.swift`, `ExtensionManager.swift`):

1. **Unpack in memory.** ArcClone parses the CRX header (v2 or v3) and the zip itself; no `unzip` process is launched.
   - Limits: 5,000 files, 50 MB per file, 200 MB in total.
   - Every entry's CRC-32 is checked.
   - Refused outright: absolute paths, `..`, backslashes, control or bidi characters, links, encrypted entries and duplicate names.
2. **Audit.** A static scan of `manifest.json` and every `.js` / `.html` file.

   | Result | Triggers |
   |---|---|
   | **Blocked** (can't be installed) | A content security policy for extension pages that allows `'unsafe-eval'`, `'unsafe-inline'` or remote or `data:`/`blob:` script sources; `<script src="https://…">`; `importScripts("https://…")`; `import("https://…")`. Any of these would let it run code that was never reviewed. |
   | **Warning** (shown before you approve) | `eval`, `new Function`, string timers, native messaging, analytics or error-reporting calls (Google Analytics, Sentry, Mixpanel, Segment and others, counted only where code sends a request), sensitive permissions (cookies, history, webRequest, scripting…), access to every website, `externally_connectable`, sandboxed pages with relaxed policies |
   | **Info** | Manifest V2, `innerHTML` / `document.write`, WebAssembly, an `update_url` (ignored), the servers the code mentions |

3. **Approve.** The dialog lists every permission, the warnings and the start of the copy's SHA-256.
4. **Pin.** The files are written owner-only (0600) to `Application Support/ArcClone/Extensions/<uuid>/` inside the app's container, excluded from backups. Their SHA-256 (over every path and file) is stored in `extensions.sealed`, which is encrypted and authenticated with the Keychain key.
5. **Verify on every launch.** Before loading, ArcClone re-reads the pinned folder and compares the hash. If anything changed, the extension isn't loaded and Settings says so.

**Updates are never automatic.** WebKit doesn't follow `update_url`, and the pinned copy can't change without failing its hash. To update, download the new `.crx`, add it (it's audited again), and remove the old version.

Extensions installed before pinning existed (loaded from your folder) are copied, audited and pinned once on their next load. If one would now be blocked, it's turned off.

**Limits of the scan.** It's a static review. It catches the ways an extension can pull in outside code and the common telemetry endpoints, but minified or obfuscated code can hide behavior. Read the code of anything that handles sensitive pages. The store's CRX signature isn't verified; the audit and the pinned hash are what's trusted. To confirm you have the same copy as someone else, compare the hash shown in Settings → Extensions.

## 3. Runtime isolation

What's enforced, and where:

| Guarantee | How |
|---|---|
| Extensions can't reach ArcClone's native bridge | The `arc` message handler exists only in the `ArcInjections` content world (`ScriptMessageBridge.attach`). Page scripts and extension content scripts run in other worlds and don't see it; the self-test checks the page world. |
| Extension pages can't use the bridge either | `ScriptMessageBridge` answers only messages from its own content world, from frames whose WebKit-reported origin is `https`, `http` or `file`. `webkit-extension:` pages are refused even when opened in a tab. |
| Only reviewed code runs | WebKit enforces each extension's CSP (Manifest V3 defaults to `script-src 'self'`). The audit refuses policies that would allow eval or remote scripts on extension pages, so the pinned files are all an extension can run. |
| Only approved permissions | Permissions and host patterns are granted explicitly at each load, from what was approved at install (`ExtensionManager.load`). |
| No extensions in private windows | Private windows use a separate configuration without the extension controller. |
| OS-level containment | Extensions run in WebKit's own processes under ArcClone's App Sandbox (outbound network only, no file access beyond what you open). |
