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

**Adding straight from the Chrome Web Store.** Paste a store link (`https://chromewebstore.google.com/detail/<name>/<id>`) or the 32-letter ID into the field in Settings → Extensions and choose **Add from Store** (`ChromeWebStore.swift`, `CRX3.swift`):

1. ArcClone downloads the package from Google's update service, with no cookies, cache or stored credentials, at most 200 MB, and only over HTTPS from Google's hosts:
   ```
   https://clients2.google.com/service/update2/crx?response=redirect&prodversion=130.0&acceptformat=crx3&x=id%3D<ID>%26installsource%3Dondemand%26uc
   ```
2. **Verify the signature.** Only CRX3 is accepted. Every RSA (2048-bit or larger) and P-256 signature in the header must verify over the signed header and the zip. One of the signing keys must hash to the requested ID. So a download that was swapped, damaged or is a different extension is refused before it's unpacked.
3. From there it's the same as adding a file: unpack, audit, approve, pin. The record remembers the store ID.

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

**Limits of the scan.** It's a static review. It catches the ways an extension can pull in outside code and the common telemetry endpoints, but minified or obfuscated code can hide behavior. Read the code of anything that handles sensitive pages. For store downloads the CRX3 signatures are checked against the requested ID (a `.crx` file you add yourself isn't, since there's no ID to check it against). Google's own publisher signature isn't pinned. The audit and the pinned hash are what's trusted after that. To confirm you have the same copy as someone else, compare the hash shown in Settings → Extensions.

## Architecture

The modules `CLAUDE.md` names live in the Swift package (`core/Sources/ArcCloneCore/`), since SwiftPM compiles sources only from there. The shim script lives in `injections/`.

| Contract | File | What it does |
|---|---|---|
| Manifest model | `Extensions/ExtensionManifest.swift` | `Codable`, `Sendable` model of MV2/MV3 manifests: content scripts, background, action, permissions, CSP, icons, `__MSG_…__` localization. Lenient: a field with an unexpected shape is treated as absent. |
| Isolated loading | `Extensions/ExtensionActor.swift` | `@globalActor ExtensionActor`. Reading, auditing, pinning and hash checks all run here, off the main thread. |
| Installed extensions | `Extensions/ExtensionLibrary.swift` | Install, audit, approval, pinning, sealed list and integrity checks, on every macOS version. |
| Store ingestion | `Extensions/ChromeWebStore.swift`, `Extensions/CRX3.swift` | Store link or ID → CRX3 download → signature and ID verification, before the usual audit. |
| Runtime, macOS 15.4+ | `Extensions/ExtensionManager.swift` | WebKit's `WKWebExtensionController`: content scripts, background, popups, `chrome.*` APIs and extension storage. It stays on the main actor because WebKit's extension types are main-thread only. |
| Script injection, macOS 14–15.3 | `Extensions/ExtensionScriptInjector.swift` | Content scripts as `WKUserScript`s, each extension in its own content world (`ArcExtension.<id>`), chosen by match patterns when a page starts loading. |
| Message bridge, macOS 14–15.3 | `Extensions/ExtensionMessageBridge.swift`, `injections/extension-compat.js` | A first-party shim gives content scripts `chrome.storage.local` / `sync` (sealed, 10 MB quota per extension) and `storage.onChanged`. It talks to native code through a handler that accepts only schema-validated `{ action, payload }` JSON from its own world. |
| Native messaging | `Extensions/NativeMessagingHostManager.swift` | See below. Never starts a process. |
| Toolbar | `UI/ExtensionToolbarView.swift` | SwiftUI popover: each extension's icon and action badge, Add and Manage. |

**Compatibility mode (macOS 14–15.3)** runs page scripts only. Popups, background scripts and service workers, `runtime.sendMessage` and most `chrome.*` APIs need WebKit's extension controller, so they return a clear error instead.

### Native messaging and password managers

ArcClone doesn't bridge extensions to desktop helper apps. 1Password's, Bitwarden's and similar helpers check the calling browser against a built-in, signed list of known browsers (Chrome, Safari, Firefox, Edge, Brave), so they would reject ArcClone however the pipes were set up. Launching other apps' binaries from the App Sandbox would also widen the attack surface for nothing.

Instead, `runtime.connectNative` and `runtime.sendNativeMessage` fail immediately with "ArcClone doesn't connect extensions to desktop apps. Sign in within the extension instead.":
- On macOS 15.4+, through `WKWebExtensionControllerDelegate`.
- On older versions, through the bridge.

Extensions can handle that error and fall back to their own features: extension storage, their popup and options pages, and web sign-in in a tab. Nothing waits on a host that will never answer.

## 3. Runtime isolation

What's enforced, and where:

| Guarantee | How |
|---|---|
| Extensions can't reach ArcClone's native bridge | The `arc` message handler exists only in the `ArcInjections` content world (`ScriptMessageBridge.attach`). Page scripts and extension content scripts run in other worlds and don't see it; the self-test checks the page world. |
| Extension pages can't use the bridge either | `ScriptMessageBridge` answers only messages from its own content world, from frames whose WebKit-reported origin is `https`, `http` or `file`. `webkit-extension:` pages are refused even when opened in a tab. |
| Only reviewed code runs | WebKit enforces each extension's CSP (Manifest V3 defaults to `script-src 'self'`). The audit refuses policies that would allow eval or remote scripts on extension pages, so the pinned files are all an extension can run. |
| Only approved permissions | Permissions and host patterns are granted explicitly at each load, from what was approved at install (`ExtensionManager.load`). |
| Extensions can't see each other or the page | Compatibility-mode content scripts run in a separate content world per extension. Page scripts can't read their variables, and `chrome` never appears in the page. |
| No extensions in private windows | Private windows use a separate configuration without the extension controller or the compatibility injector. |
| No desktop helpers | Native messaging is refused without starting any process. |
| OS-level containment | Extensions run in WebKit's own processes under ArcClone's App Sandbox (outbound network only, no file access beyond what you open). |
