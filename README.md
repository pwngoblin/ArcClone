# Lily

A native macOS browser in the spirit of Arc: vertical tabs in a sidebar, spaces with separate logins, split view, a command palette, and a local AI assistant that can summarize the page or YouTube video you're on and explain selected text.

Lily is written in Swift with AppKit and SwiftUI and renders pages with WebKit (`WKWebView`), the engine Safari uses. There is no Electron, no bundled Chromium and no Node; the only JavaScript is the set of scripts in `injections/` that run inside web pages. The assistant talks to [Ollama](https://ollama.com) on your Mac.

> **Renamed from ArcClone.** Lily is a new app identity (`dev.lily.browser`): macOS gives it its own sandbox container and Keychain items, so it starts without ArcClone's session, history, bookmarks, extensions or website data. Re-import bookmarks and history with File → Import from Another Browser, then delete ArcClone.

> **Status:** early development (0.x). Everything listed under [Features](#features) is implemented and covered by tests or the self-test; [Known issues and limitations](#known-issues-and-limitations) lists what isn't finished, what is deliberately not supported, and what still needs a human to try.

**Contents:** [Install](#install) · [Features](#features) · [Keyboard shortcuts](#keyboard-shortcuts) · [Privacy](#privacy) · [Security](#security) · [Architecture](#architecture) · [Where things are](#where-things-are) · [Development](#development) · [Adding a feature](#adding-a-feature) · [Known issues and limitations](#known-issues-and-limitations) · [Releases](#releases)

## Install

1. Download a DMG from [Releases](https://github.com/pwngoblin/Lily/releases), or from a workflow run's artifacts.
2. Open it and drag **Lily** to **Applications**.
3. Builds without a Developer ID signature are blocked on first launch: open **System Settings → Privacy & Security** and click **Open Anyway**.

**Requirements**
- macOS 14 Sonoma or later, Apple silicon or Intel. Full web extension support (popups, background) needs macOS 15.4 or later.
- For the assistant only: [Ollama](https://ollama.com) with at least one model (`ollama pull llama3.2`).

## Features

**Tabs and windows**
- A sidebar with pinned tabs as rounded tiles and regular tabs below. Right-click for duplicate, pin, copy link, share, pause media, open in new window, split, move to another space, and close tab / others / below.
- **Drag and drop**: reorder tabs and pinned tiles (pinned tiles are a native AppKit grid that parts to show where a tab will land); drop a tab on a pinned tile to pin it there, or drag a pinned tile into the list to unpin it; drop a tab on a space icon to move it to that space, or on a split pill to add it to that split. Links dragged from a page or another app open where you drop them (web links only). A tab dragged into another app gives its address. On a Force Touch trackpad you feel a tap when you pick a tab up, as you move over each place it can go, and when it lands.
- **Spaces**: separate sets of tabs, each with a name, icon and color that tints the sidebar. Switch with a two-finger horizontal swipe on the sidebar, the switcher in the sidebar footer, or ⌥⌘] / ⌥⌘[. Turn on **Separate logins** (Edit Space) to give a space its own cookies and site data, so you can be signed in to a site with a different account in each space.
- **Split view**: two side by side, two stacked, three columns, three rows, or a 2×2 grid. Click a pane to focus it. Each split appears in the sidebar as one pill arranged like the split, and you can keep several splits at once. **Link Scrolling** (⌃⌘L) keeps the panes in step for comparing documents. Panes you haven't used for 5 minutes pause (no scripts, animations or rendering) until you click or scroll them; set this in Settings → Tabs.
- **Command bar** (⌘T, ⌘L): opens addresses, searches with your chosen engine, and suggests open tabs, bookmarks and history.
- **Command palette** (⌘K): the command bar plus every menu command (with its shortcut), your spaces and your extensions. Type `>` for commands only.
- **Find in page** (⌘F, ⌘G / ⇧⌘G): a find bar over the page with a match count; WebKit highlights and scrolls to each match.
- **Typed text recovery**: text typed into long fields (comments, posts, messages) is kept for 24 hours, encrypted, so it can be restored if the page crashes or closes before you send it (History → Restore Typed Text). Never passwords, card fields or private windows.
- **Little Lily**: links from other apps (Mail, Slack, Notes…) open in a small window for one page, like Little Arc, instead of piling up as tabs. **Open in Lily** (⇧⌘O) moves the page into your main window as it is: same scroll position, typed text and video, no reload. Also File → New Little Lily Window (⌥⌘N) and Open Link in Little Lily in a page's menu. Turn it off in Settings → General to open links as tabs. How it works: [docs/LITTLE_LILY.md](docs/LITTLE_LILY.md).
- **Private windows** (⇧⌘N): in-memory website data that is never saved, no history, no typed-text recovery, no extensions, and a request to macOS to keep the window out of screen capture.
- **Sleeping tabs**: background tabs unused for 15 minutes (configurable, 5 in Low Power Mode) release their web view entirely to free memory and come back where you left off. Tabs playing media, using the camera or microphone, or in a visible split stay awake. Memory pressure from macOS puts eligible tabs to sleep immediately. The app doesn't poll for this: it wakes only when a tab is due to sleep. Restored and imported tabs load only when you first open them, so thousands of tabs cost about a kilobyte each.
- Tabs, pinned tabs, spaces and opened files (*File → Open File…*) are restored on launch.

**Pages**
- **Site settings** per website (toolbar button or ⌥⌘,): zoom, appearance, JavaScript, ads, camera and microphone, and clearing the site's data.
- **Dark mode for websites** (⌥⌘D): use the site's own dark theme, or *Force Dark* to invert sites without one while keeping images and video natural.
- **Site security**: the lock next to the address shows whether the connection is secure (or mixes in insecure content), the certificate's subject, issuer and expiry with the system certificate viewer, your settings for the site, and whether it stores data.
- **Ad and tracker blocking** with WebKit content rules: a built-in list, YouTube ad skipping, and a toolbar shield to allow ads on a site. Filter lists can be turned on in Settings → Privacy: EasyList, EasyPrivacy, uBlock filters, uBlock filters – Privacy, Peter Lowe's list and AdGuard Annoyances. They're downloaded weekly and converted from Adblock Plus / uBlock Origin syntax, including exceptions, `$domain=`, `$important`, `$badfilter`, element hiding, and procedural filters (`:has-text()`, `:upward()`, `:style()` limited to layout properties) that run in the page. Scriptlets (`+js`), redirects and other filters that would run list-supplied code, or that WebKit can't express exactly, are skipped.
- **HTTPS-First**: `http://` addresses are tried over HTTPS first; falling back to HTTP asks you.
- **Link tracking protection**: click and campaign identifiers (`utm_…`, `fbclid`, `gclid` and similar) are removed from links you click, type, open from other apps or copy (Settings → Privacy, on by default).
- **Downloads**: a progress ring and badge in the sidebar, and a popover with progress, time remaining, cancel, retry (resuming when possible) and Show in Finder.
- **Web extensions**: Chrome, Firefox and Safari web extensions from a folder, .zip, .crx, or straight from a **Chrome Web Store link or ID** (Settings → Extensions → Add from Store). Store downloads are verified like Chrome does (CRX3 signatures, the developer key matching the ID, and the Web Store's own publisher signature). Every extension is audited before installing: anything that could load code from outside the extension is refused, and eval, telemetry calls and sensitive permissions are shown with every permission. The approved copy is pinned in the app's container, checked against its SHA-256 at every launch, and never updates on its own (re-adding a newer store version updates it in place, keeping its data). On macOS 15.4+ they run fully through WebKit, with a small compatibility layer for Chrome APIs WebKit doesn't have; on macOS 14–15.3 their page scripts run, each in its own content world, with `chrome.storage`. Extensions can't reach Lily's page bridge. See [docs/EXTENSIONS.md](docs/EXTENSIONS.md).

**History and bookmarks**
- A History window (⌘Y) with time ranges, most-visited sites and search; a History list in the sidebar (clock button); recently visited pages in the History menu. Private windows are never recorded.
- **Import from another browser** (File → Import from Another Browser…): bookmarks and history from Google Chrome, Safari, Arc, Dia and Zen, and Arc's spaces and tabs.
  - You grant read-only access once to `~/Library/Application Support` and `~/Library/Safari`; the grant is remembered as security-scoped bookmarks.
  - Browser databases are copied and read with SQLite in read-only mode, so the other browsers are never changed.
  - Addresses are cleaned of tracking parameters, duplicates across browsers are merged, and only web links are kept.
  - Imported Arc tabs stay unloaded until opened.
  - macOS protects some browsers' data (Safari, and Chrome on recent versions); those need Full Disk Access for Lily, and the import window says so.
- Bookmarks appear in the Bookmarks menu and in command bar suggestions, and are encrypted at rest like history.

**Assistant** (⌘E)
- Ask about the current page, summarize a page or a YouTube video from its transcript (⇧⌘E), or explain selected text. Timestamps in answers jump to that point in the video.

**Web developers**
- Settings → General → *Show features for web developers* (off by default): Inspect Element in the page's context menu, Develop → Show Web Inspector (⌥⌘I), and inspecting Lily's pages and extension pages from Safari's Develop menu. It applies to open pages at once.

**macOS integration**
- Native toolbar, a trimmed menu bar (no Spelling, Substitutions, Speech, Dictation or Emoji items: WebKit's text-field menu and Fn/Globe cover them; macOS window tabbing is off since Lily has its own tabs), printing, and a Settings window (⌘,) with General, Tabs, Appearance, Websites, Privacy, Extensions and Assistant panes.
- A page context menu with icons, including Open Link in New Tab and Open Link in Split View.
- Can be the default browser; opens `http`/`https` links and HTML files.
- **Handoff**: a page open in Safari (or another browser) on your iPhone, iPad or another Mac opens in Lily when you click the Handoff icon at the end of the Dock, as a new tab in your main window, also when Lily isn't running yet. It needs Lily as your default browser (Settings → General) and Handoff turned on in System Settings → General → AirDrop & Handoff on both devices. Only web pages are accepted, and trackers are removed from the address as for any opened link. The other direction, offering Lily's current page to your other devices, is off by default, since it shares each page's address and title (Settings → Privacy → Continue pages on other devices).
- Haptic feedback on Force Touch trackpads for reordering and dragging tabs, pinning, splitting, switching spaces and crossing the space-swipe threshold (Settings → General).
- Appearance: accent color, sidebar color and strength, a paper-like grain, and System / Light / Dark.
- Release DMGs are universal binaries (arm64 + x86_64).

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘T / ⌘L | New tab / edit the current address |
| ⌘K | Command palette (`>` for commands only) |
| ⌘F / ⌘G / ⇧⌘G | Find in page / next / previous match |
| ⌘N / ⇧⌘N / ⌥⌘N | New window / new private window / new Little Lily window |
| ⇧⌘O | Open in Lily (move a Little Lily page into the main window) |
| ⌘W / ⇧⌘T | Close tab / reopen closed tab |
| ⌘1–⌘8, ⌘9 | Go to a tab / the last tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘D | Pin or unpin tab |
| ⌥⌘] / ⌥⌘[ | Next / previous space |
| ⌃⌘1–⌃⌘5 / ⌃⌘0 | Split view layouts / exit split view |
| ⌃⌘L | Link scrolling in split view |
| ⌘S | Toggle sidebar |
| ⌘E / ⇧⌘E | Toggle assistant / summarize page |
| ⌘[ / ⌘] | Back / forward |
| ⌘R / ⇧⌘R | Reload / reload ignoring cache |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / actual size (remembered per site) |
| ⌥⌘D / ⌥⌘, | Dark mode for this site / site settings |
| ⌘Y | History |
| ⇧⌘⌫ | Clear browsing data |
| ⇧⌘C | Copy link |
| ⌘O / ⌘P | Open file / print |
| ⌥⌘I | Show Web Inspector (with web developer features on) |
| ⌘, | Settings |

## Privacy

No account, no telemetry, no analytics, no crash reporting of its own, and DuckDuckGo as the default search engine. What Lily stores stays on your Mac, encrypted; what it sends is what browsing needs. Site icons in lists come from your own visits, never by contacting the sites in them; trackers are taken out of links; Lily presents exactly as this Mac's Safari so it doesn't stand out; Handoff is off unless you turn it on; private windows keep nothing, and their downloads don't record where they came from. Everything Lily keeps (and for how long), everything it sends (and to whom), and what isn't covered yet: [docs/PRIVACY.md](docs/PRIVACY.md).

## Security

| Area | What Lily does |
|---|---|
| **Data at rest** | The session, history, bookmarks, site settings, typed-text drafts, the installed-extension list and extension storage are encrypted with AES-GCM using a key in your Keychain (`…AfterFirstUnlockThisDeviceOnly`, with an access list that trusts only Lily), written owner-only (0600) with file protection and excluded from backups. Logs keep URLs private. *Clear Browsing Data* removes website data (every space's store included), the session, history, typed-text drafts and the assistant's context. |
| **Network** | HTTPS-First for page navigations. The app's own connections use TLS 1.2+ under App Transport Security. Chrome Web Store downloads use an ephemeral session (no cookies, cache or credentials) and are signature-verified. Ollama may use plain HTTP only on this Mac; a remote host must use HTTPS and can be pinned by SPKI SHA-256 (*Settings → Assistant*), checked after normal certificate validation. Websites use WebKit's TLS validation with no overrides. |
| **Sandbox** | App Sandbox with a minimal entitlement list ([`scripts/Lily.entitlements`](scripts/Lily.entitlements)), no temporary exceptions, no helper processes. Files are opened through the open panel and reopened with read-only security-scoped bookmarks. Downloads are quarantined. Opening another app through a link always asks first. |
| **Code integrity** | Hardened runtime with library validation, no JIT and no DYLD environment variables. Only system libraries are loaded (including `/usr/lib/libz`) and only the `/usr/lib/swift` rpath is kept. Packaged builds ignore developer environment overrides and check their own signature and resources at launch, refusing to run if modified. |
| **Pages and scripts** | Injected scripts run in an isolated WebKit content world that websites can't reach. Their messages are decoded into fixed schemas with size limits and must match the frame's real origin. Native code passes data to scripts as arguments, never by building JavaScript strings. JavaScript dialogs name the real origin and can be silenced. Pages can't navigate a tab to a `data:` URL. |
| **Extensions** | Audited, pinned by hash and re-verified at every launch; permissions granted only as approved; no access to Lily's bridge; never in private windows; native messaging refused without starting any process. Details in [docs/EXTENSIONS.md](docs/EXTENSIONS.md). |
| **Other apps** | Copies made in private windows are marked so clipboard managers skip them. There is no AppleScript interface. A dragged tab carries a random tab id that means nothing outside Lily (list rows offer it to Lily only; pinned tiles use the AppKit drag pasteboard) and its web address. Website data (cookies, storage, caches) is written by WebKit inside the app container: on macOS 14+ a Developer ID-signed build's container is protected from other apps, and *Clear cookies and website data when Lily quits* removes it. |
| **Release builds** | Stripped binaries (the dSYM is kept separately), no `get-task-allow`. Web Inspector is off unless you turn on web developer features; its two non-public WebKit hooks are used only after checking they exist. |

[`scripts/verify-app.sh`](scripts/verify-app.sh) runs on every `make app` and in CI. It fails the build if the signature and sealed resources, hardened runtime, entitlement allowlist, load commands, Info.plist rules, symbol stripping or secret scan don't pass. [`scripts/security-lint.sh`](scripts/security-lint.sh) runs before every commit and in CI (see [Development](#development)).

The assistant sends page text to Ollama over HTTP on this Mac. While Ollama isn't running, another local program could listen on its port, so use the assistant on a Mac you trust.

**Signing note:** ad-hoc builds store the encryption key per build, so the saved session doesn't survive an update; Developer ID builds keep it.

## Architecture

### The big picture

```
┌──────────────────────────── Lily (app process, sandboxed) ────────────────────────────┐
│                                                                                            │
│  AppDelegate ── owns app-wide services ────────────────────────────────────────────────┐   │
│   │  WebViewFactory (data stores, script registry)   History · Bookmarks · FormDrafts   │   │
│   │  SiteSettings · AdBlocker · DownloadManager      SessionStore · ExtensionLibrary     │   │
│   │  Assistant (Ollama)                              ExtensionManager (macOS 15.4+)      │   │
│   │                                                                                     │   │
│   └─ BrowserWindowController (one per window) ──────────────────────────────────────┐   │   │
│        TabStore ── Tab ── WKWebView (made on first use, released when asleep)       │   │   │
│        WindowModel (@Observable) ── SwiftUI: sidebar, command bar/palette, toasts   │   │   │
│        TabContentViewController ── panes, split layouts, find bar, paused panes     │   │   │
│        IPCRouter ── page routes (PageHandlers) ─────────────┐                       │   │   │
│        TabSleeper · PaneFreezer · FindModel                  │                       │   │   │
└──────────────────────────────────────────────────────────────┼───────────────────────────┘
                                                               │ WKScriptMessageHandlerWithReply
┌───────────── WebKit processes (WebContent per site, Network, GPU) ─────────────────────────┐
│   page world: the website's own scripts             (can't see anything below)             │
│   LilyInjections world: injections/modules/*.js ── window.__lily.send / emit / register      │
│   LilyExtension.<id> worlds: compatibility-mode extension content scripts (macOS 14–15.3)   │
│   extension contexts: WKWebExtensionController backgrounds, popups (macOS 15.4+)           │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **One app process, no helpers.** Pages run in WebKit's own processes; Lily launches nothing else.
- **Main actor for UI and WebKit, actors for I/O.** Everything that touches AppKit, SwiftUI or WebKit is `@MainActor`. Slow file work runs on dedicated actors: `ExtensionActor` (reading, auditing, hashing and pinning extensions), `MigrationActor` (reading other browsers' databases), `SessionStore` and the Keychain key store. Encryption and writes run off the main thread. The package builds in Swift 6 language mode, so data races are compile errors.
- **No polling.** Timers are single scheduled wake-ups with tolerance (tab sleep, pane pausing, debounced saves). Pages report changes through events, never through native code asking repeatedly.

### Startup

`Lily/main.swift` starts `AppDelegate`, which in order:
1. checks the app's own code signature (`CodeIntegrity`) and refuses to run if it was modified;
2. loads the injection manifest (`ScriptRegistry`) from `injections/`, which is in the app's resources in packaged builds and in the repo during development (`AppPaths`);
3. loads site settings and the ad blocker's compiled rules, then builds the shared `WebViewFactory`;
4. on macOS 15.4+ creates the extension runtime (`ExtensionLibrary` → `ExtensionManager`), otherwise the compatibility injector; extensions load in the background;
5. loads the session store, history, typed-text drafts, bookmarks and migration grants (each decrypting its sealed file);
6. opens the first window and restores the session (tabs come back unloaded except the active one), or opens links passed on the command line.

`--self-test` runs the same startup with in-memory history and drafts, then [`App/SelfTest.swift`](core/Sources/LilyCore/App/SelfTest.swift).

### Tabs, web views and memory

- A **`Tab`** is cheap until it's shown: its `WKWebView` (and with it a web content process) is created on first use of `tab.webView` and released when the tab sleeps, keeping its back/forward list and scroll position (`interactionState`). Restored and imported tabs start asleep. This is what lets 5,000+ tabs cost about a kilobyte each (`TabManagerPerformanceTests`).
- **`TabStore`** (one per window) owns the ordered tabs, the active tab, spaces, split groups and recently closed tabs. Pinned tabs always sort first; split groups move as one block.
- **`TabSleeper`** releases web views of background tabs idle past the threshold, except tabs playing media, capturing camera or microphone, or in the visible split. It schedules one wake-up for the next tab that could sleep.
- **`PaneFreezer`** pauses unfocused split panes: the pane is covered with its snapshot and its web view hidden, so WebKit suspends it (`inactiveSchedulingPolicy = .suspend`, set for every web view). The self-test measures it: 95 animation frames in 1.5 s running, 0 while paused.
- **Spaces and data stores.** `WebViewFactory.dataStore(forSpace:)` returns the shared persistent store, or for a space with Separate logins its own `WKWebsiteDataStore(forIdentifier: space.id)`. A tab gets its space before its first web view is made; switching the toggle or moving a tab between stores rebuilds its web view (`Tab.rebuildWebView`). Private windows use a separate factory with one non-persistent store and no extensions.
- **Display.** `TabContentViewController` shows the active tab, or its split as rounded panes in `NSSplitView`s, plus the find bar slot above them. The sidebar is SwiftUI, fed by `WindowModel`, which `BrowserWindowController` refreshes at most once per run-loop pass (`scheduleSnapshot`).

### Pages and native code (IPC)

```
injections/modules/x.js                         core (Swift)
  lily.send("type", payload)  ──request──▶  ScriptMessageBridge ─▶ IPCRouter ─▶ route handler ─▶ reply
  lily.emit("type", payload)  ──event────▶  (same, no reply)
  lily.register("name", fn)   ◀──invoke───  tab.callInjection("name", args)   (callAsyncJavaScript, args as JSON)
```

- **Wire format**: versioned JSON envelopes `{ v, id, kind, type, payload }` (`IPC/IPCEnvelope.swift`, `injections/modules/runtime.js`), at most 256 KB.
- **Who can send**: the `arc` message handler exists only in the isolated `LilyInjections` content world. `ScriptMessageBridge` accepts messages only from that world and from `https`, `http` or `file` frames; the source (tab, main frame or not, origin) comes from WebKit's view of the frame, never from the page.
- **Routes** are registered with a schema: `router.on("type", from: [.page], as: Payload.self)`. Payloads decode into `Decodable` structs with length limits (`Handlers/PagePayloads.swift`), and URLs are checked against the frame's real origin (`PagePayload.sameOrigin`). The security lint rejects routes without a schema. Current page routes: `page.didChange`, `selection.changed`, `selection.cleared`, `youtube.videoChanged`, `adblock.procedural`, `runtime.error`, `form.snapshot`, `form.clear`, `scroll.changed`.
- **Native → page** calls go through `Tab.callInjection(name, args)`, which passes arguments as JSON through `callAsyncJavaScript`'s argument dictionary. JavaScript is never built from strings, and `evaluateJavaScript` is allowed only in the self-test (lint-enforced).

**Injected modules** ([`injections/manifest.json`](injections/manifest.json); all in the `LilyInjections` world)

| Module | Frames | Sites | What it does |
|---|---|---|---|
| `runtime.js` | all | all | `window.__lily`: send / emit / register, the wire protocol |
| `page-metadata.js` | main | all | title, favicon, theme color, SPA navigations → `page.didChange` |
| `dom-extractor.js` | main | all | readable text, outline, links, selection for the assistant |
| `selection-capture.js` | all | all | meaningful selections (never in form fields) → `selection.changed` |
| `dark-mode.js` | main | all | site dark theme / Force Dark |
| `cosmetic-filter.js` | main | all | procedural element hiding from filter lists |
| `youtube-transcript.js` | main | youtube.com | transcripts for the assistant |
| `youtube-adblock.js` | main | youtube.com | skips and hides YouTube ads |
| `form-recovery.js` | main | all | typed-text drafts → `form.snapshot` / `form.clear`; `form.restore` |
| `scroll-sync.js` | main | all | Link Scrolling positions → `scroll.changed`; `scroll.apply` |
| `find-count.js` | main | all | match count for the find bar |

Two more scripts are not page modules: `injections/extension-compat.js` (`chrome.storage` for compatibility-mode content scripts) and `injections/extension-worker-compat.js` (stand-ins added to Chrome-built extension backgrounds; see [docs/EXTENSIONS.md](docs/EXTENSIONS.md)).

### Storage

Everything lives in the app container's `Application Support/Lily/`. Sealed files are AES-GCM encrypted with a per-purpose Keychain key (`SealedFile` in `Support/SecureStorage.swift`).

| File | Owner | Contents |
|---|---|---|
| `session.sealed` | `SessionStore` | open tabs, pinned state, spaces (incl. Separate logins), active tab |
| `history.sealed` | `History` | visits (90 days by default, at most 20,000) |
| `bookmarks.sealed` | `Bookmarks` | imported bookmarks |
| `sites.sealed` | `SiteSettings` | per-site zoom, dark mode, JavaScript, permissions, ads allowed |
| `favicons.sealed` | `FaviconLoader` | site icons kept from visits (at most 32 px, 600 sites); they follow history |
| `form-drafts.sealed` | `FormDrafts` | typed-text drafts, 24 h, at most 200 × 40,000 characters |
| `extensions.sealed` | `ExtensionLibrary` | installed extensions, granted permissions, pinned hashes, store IDs |
| `ExtensionStorage/<id>.sealed` | `ExtensionStorage` | `chrome.storage` for compatibility-mode extensions |
| `Extensions/<uuid>/` | `ExtensionLibrary` | pinned extension files (0600), re-hashed at every launch |
| `FilterLists/` | `AdBlocker` | downloaded filter lists and compiled rules |
| `migration-access.sealed` | `MigrationAccess` | security-scoped bookmarks to other browsers' folders |
| WebKit data stores | WebKit | cookies, storage, caches: the default store, plus one per space with Separate logins |

Preferences (non-sensitive) are in `UserDefaults` (`Support/Preferences.swift`). Secrets never are.

### Web extensions

Install, audit, pinning and verification work on every macOS version (`ExtensionLibrary`, file work on `ExtensionActor`). Running them has two runtimes: WebKit's `WKWebExtensionController` on macOS 15.4+ (`ExtensionManager`, host protocols in `Browser/ExtensionSupport.swift`), or content scripts only on macOS 14–15.3 (`ExtensionScriptInjector`, `ExtensionMessageBridge`). Store ingestion is `ChromeWebStore` + `CRX3`; the compatibility layer for missing Chrome APIs is `ExtensionCompat` + `injections/extension-worker-compat.js`. The full design, the audit rules and the isolation guarantees are in [docs/EXTENSIONS.md](docs/EXTENSIONS.md).

### How the architecture rules map to the code

[`CLAUDE.md`](CLAUDE.md) describes the project as `core/`, `injections/`, `agent-bridge/` and `ui/` modules. SwiftPM compiles sources only from a package's `Sources/`, so the Swift "modules" are folders of the one `LilyCore` target:

| Rule's module | Where it is |
|---|---|
| `core/migration/` | `core/Sources/LilyCore/Migration/` |
| `core/tabs/` | `core/Sources/LilyCore/Browser/` (`Tab`, `TabStore`, `TabSleeper`, `PaneFreezer`, `SplitView`) |
| `core/workspaces/` | spaces in `Browser/TabStore.swift`, data stores in `Browser/WebViewFactory.swift` |
| `core/session/` | `core/Sources/LilyCore/Session/` (`FormDrafts`) and `Support/SessionStore.swift` |
| `core/` extensions (`ExtensionManifest`, `ExtensionManager`) | `core/Sources/LilyCore/Extensions/` |
| `injections/` (Swift side: `ExtensionScriptInjector`, `ExtensionMessageBridge`) | `Extensions/` and `Scripts/`; the JavaScript is in the top-level `injections/` |
| `agent-bridge/` (`NativeMessagingHostManager`) | `Extensions/NativeMessagingHostManager.swift` (refuses; see known issues) |
| `ui/` | `core/Sources/LilyCore/UI/` |

## Where things are

```
core/                     Swift package (Package.swift: Swift 6 mode, no dependencies)
  Sources/Lily/       main.swift: the executable's entry point
  Sources/LilyCore/   the app (library target, so tests can reach it)
  Tests/LilyCoreTests/  Swift Testing suites
injections/               JavaScript for pages and extension shims, manifest.json
scripts/                  bundle.sh, verify-app.sh, security-lint.sh, make-dmg.sh, make-icon.swift, entitlements
docs/EXTENSIONS.md        extension design, audit, pinning, isolation, native messaging policy
.github/                  CI (test, package, audit, self-test), DMG/release workflow, branch hygiene, PR template
.githooks/pre-commit      runs the security lint (enable with `make hooks`)
CLAUDE.md                 engineering rules (architecture, security, performance, git workflow)
CONTRIBUTING.md           branches, PRs, stacked PRs, releases
```

**`core/Sources/LilyCore/`**

| Folder | Files | Responsibility |
|---|---|---|
| `App/` | `AppDelegate`, `MainMenu`, `SettingsWindowController`, `DefaultBrowser`, `SelfTest` | Startup, app-wide services, menus, Settings panes, default-browser registration, the self-test |
| `Browser/` | `BrowserWindowController` (+`Commands`), `Tab`, `TabStore`, `WebViewFactory`, `BrowserWebView`, `SplitView`, `TabSleeper`, `PaneFreezer`, `FindInPage`, `WebInspector`, `LittleLily`, `HTTPSFirst`, `URLResolver`, `DownloadManager`, `WindowToolbar`, `ExtensionSupport` | Windows, tabs and their web views, menus and shortcuts, split panes, sleeping and pausing, find, navigation policy, downloads, the toolbar, extension host protocols |
| `UI/` | `SidebarView`, `PinnedTabsGrid`, `TabMenu`, `WindowModel`, `CommandBarView`, `CommandPalette`, `TabDragDrop`, `HistoryView`, `HistoryPanelView`, `AssistantPanelView`, `AssistantChat`, `SiteSettingsView`, `SiteSecurityView`, `DownloadsView`, `ExtensionToolbarView`, `ExtensionsSettingsView`, `MigrationView`, `Appearance`, `FaviconView`, `FullscreenNotice` | Window chrome: the SwiftUI sidebar with a native AppKit pinned-tile grid, the shared tab menu (SwiftUI and NSMenu), spaces, drag and drop, command bar and palette, toasts and haptics, panels and popovers |
| `IPC/` | `IPCEnvelope`, `IPCRouter`, `ScriptMessageBridge` | The page ↔ native wire format, routing and source checks |
| `Handlers/` | `PageHandlers`, `PagePayloads`, `PageContext` | Page routes, their schemas and limits, page context for the assistant |
| `Scripts/` | `ScriptRegistry`, `InjectionManifest` | Loading and validating `injections/manifest.json` into `WKUserScript`s |
| `Extensions/` | `ExtensionLibrary`, `ExtensionManager`, `ExtensionManifest`, `ExtensionPackage`, `ExtensionAudit`, `ExtensionActor`, `ExtensionCompat`, `ChromeWebStore`, `CRX3`, `ExtensionScriptInjector`, `ExtensionMessageBridge`, `ExtensionStorage`, `NativeMessagingHostManager` | Installing, verifying and running web extensions |
| `AdBlock/` | `AdBlocker`, `FilterListConverter`, `FilterLists`, `BuiltinBlocklist`, `CosmeticSelector` | Content-rule compilation, filter-list download and conversion, procedural filters |
| `Agent/` | `Assistant`, `OllamaClient`, `Prompts`, `AssistantModels`, `AssistantContextStore` | The local assistant |
| `Migration/` | `MigrationEngine`, `MigrationModel`, `MigrationModels`, `BrowserReaders`, `SQLiteReader`, `MigrationAccess` | Importing from Chrome, Safari, Arc, Dia and Zen |
| `Session/` | `FormDrafts` | Typed-text recovery |
| `Support/` | `SecureStorage`, `SessionStore`, `History`, `Bookmarks`, `SiteSettings`, `LinkTracking`, `Preferences`, `AppPaths`, `CodeIntegrity`, `CertificatePinning`, `Clipboard`, `Sanitize`, `JSONValue`, `Log` | Encryption and storage, settings, paths, integrity, pinning, sanitizing, logging |

## Development

Requires Xcode 16 or later (Swift 6).

```sh
make            # build core/
make run        # run the development build from the repository
make check      # security lint + Swift tests (what CI runs first)
make test       # check, then the end-to-end self-test
make perf       # performance gate: 5,000-tab memory and search speed, tab virtualization
make selftest   # boot the app headlessly-ish and run the self-test
make app        # build/Lily.app, then scripts/verify-app.sh
make dmg        # build/Lily-<version>.dmg
make hooks      # run the security lint before every commit in this clone
```

`make app` options: `UNIVERSAL=1` builds arm64 + x86_64, `VERSION` / `BUILD_NUMBER` override the version, and `CODESIGN_IDENTITY` signs with a certificate (ad-hoc otherwise).

**CI** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `make check`, `make app` (with `verify-app.sh`) and the packaged app's `--self-test` on every PR.

**The security lint** ([`scripts/security-lint.sh`](scripts/security-lint.sh)) fails on: `print`/`NSLog`, process spawning, unsafe pointer types (except a parameter AppKit itself declares as a pointer, on a line marked `// AppKit API signature`), XPC without peer validation, log interpolations without a privacy qualifier, page routes without a schema, `evaluateJavaScript` outside the self-test, `eval`/`Function`/`innerHTML`/string timers/`setInterval` in injections, unpinned dependencies, committed secrets, and shell scripts without strict mode, a fixed `PATH` and private temp files.

**The self-test** (`Lily --self-test`, also run on the packaged app in CI) boots the real app and checks, in WebKit: the injection runtime and its host guard, page events and history, `dom.extract`, procedural filters, the download animation, typed-text recovery (draft kept, card field and query string not, restore offered and applied), Link Scrolling (a 12,000 px pane follows a 6,000 px one to the same fraction), paused panes (animation frames stop), Little Lily (Open in Lily keeps the same page, typed text and scroll position, and its messages reach the main window), find in page, tab drag and drop, the native pinned tiles (rendered, AppKit drag pasteboard, drop lands in the gap), web developer features matching the setting, the trimmed menu bar, the command palette against the live menus, internal pages without scripts, migration inside the sandbox, page-world isolation, the assistant, and encrypted session storage. `LILY_SELFTEST_NETWORK=1` adds live checks of HTTPS-First and certificate pinning. It prints a JSON report and exits non-zero on failure.

**Tests** (`core/Tests/LilyCoreTests/`, Swift Testing, about 220 tests) cover each area by file name: tabs and spaces (`SpacesTests`, `WorkspaceTests`, `SplitViewTests`, `ScrollLinkTests`, `TabSleepTests`, `PaneFreezerTests`, `TabManagerPerformanceTests`), IPC and payloads (`CoreTests`, `InjectionAuditTests`), storage and privacy (`HistoryTests`, `FormDraftsTests`, `SiteSettingsTests`, `ThreatHardeningTests`, `SecurityReviewTests`, `SecurityStandardsTests`), extensions (`ExtensionTests`, `ExtensionPackageTests`, `ExtensionRuntimeTests`, `ExtensionCompatTests`, `ChromeWebStoreTests`), the command palette, ad blocking, migration, downloads, the link menu, platform controls and the assistant.

How to branch, open and merge pull requests (including stacked PRs), and cut releases is in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Adding a feature

A checklist that matches how the existing features are built:

1. **Branch** from an up-to-date `main` (`feature/…`, `fix/…`); conventional, atomic commits that each build.
2. **Page behavior?** Add `injections/modules/<name>.js`: an IIFE that exits if `window.__lily` is missing or it already ran; talk to native code only through `lily.send` / `lily.emit` / `lily.register`; react to events (debounce with `setTimeout` taking a function), never poll; treat anything native sends as data. Add it to `injections/manifest.json` with the narrowest `matches` and frames it needs.
3. **New route?** Add a `Decodable` payload with limits to `PagePayloads.swift`, register it with `router.on(…, as:)` in `PageHandlers.swift`, take the origin from `ctx.source`, and check URLs with `PagePayload.sameOrigin`.
4. **Storing user data?** Use a `SealedFile` with its own key name and purpose, keep nothing in private windows, add it to *Clear Browsing Data*, and bound its size and age.
5. **Background work?** Schedule one wake-up with tolerance (see `TabSleeper`, `PaneFreezer`); do file I/O on an actor, not the main thread.
6. **Menu command?** Add it to `MainMenu.swift` with an action on `BrowserWindowController` and validate it in `validateMenuItem`; it appears in the command palette automatically.
7. **Tests**: unit tests for the logic and payloads, and a self-test check when it needs WebKit. Touching `Tab`, `TabStore` or the sidebar: run `make perf`.
8. **Before the PR**: `make check`, `make selftest`, `make app`. Describe the security impact in the PR template. Update this README.

## Known issues and limitations

What's not finished, what's deliberately unsupported, and what still needs a person to try. Please keep this list current.

**Needs manual verification**
- **Drag-and-drop gestures** (PR #48). Every drop is covered by the self-test, but the physical trackpad drags aren't: row onto a pinned tile, pinned tile into the list, row onto a space icon or split pill, a link from a page into the list, a row into another app (should paste the address), plain reordering still working, and the haptic taps.
- **1Password from the Chrome Web Store.** It installs and its background starts. Until an account is added in the extension, clicking it opens 1Password's welcome page in a tab instead of a popup: 1Password turns its popup off (`action.setPopup("")`) when neither the desktop app nor an account is connected, as it does in Chrome. Signing in on that page (email, Secret Key and password, or the QR code) adds the account. Before PR #64 the sign-in froze 1Password's background as soon as it was accepted (WebKit deadlocks on a WebSocket in an extension's service worker), so the page kept spinning and the popup and autofill never answered. Re-add 1Password after updating so it gets the new shim, then check sign-in, the popup and autofill.
- The manual steps in the test plans of PRs #44–#48 (Separate logins with two accounts, ⌘K, restoring typed text after closing a tab, Link Scrolling, a pane pausing after 5 minutes, Add from Store).

**Not done yet**
- **Optimizing for size.** `-Osize` would make the binary about 31% smaller (3.6 → 2.5 MB), but CLAUDE.md requires `-O` for release builds, so it stays `-O` until that rule changes.
- **More of the UI in AppKit.** The pinned tiles are native; the rest of the sidebar, the command bar, Settings, History and the assistant are SwiftUI (the regular tab list is SwiftUI's `List`, which AppKit's table view backs).
- **Writing Tools** stays in the Edit menu: macOS adds it, with no supported way to leave it out.
- **1Password desktop-app unlock** waits on an Apple Developer Program membership. 1Password's *Add browser* refuses Lily ("signed in an unsupported way or may be missing a required identifier") because builds are ad-hoc signed, with no team ID. With Developer ID signing, the next step is a native messaging host for 1Password's helper behind a setting that's off by default, and finding out whether the helper works when started from Lily's sandbox. Until then native messaging stays refused (below).

**Limitations by design**
- **No native messaging.** `connectNative` / `sendNativeMessage` fail immediately, so password managers can't unlock through their desktop app; they work with their own sign-in. Desktop helpers check the calling browser against a signed list Lily isn't on, and launching other apps' binaries from the sandbox would widen the attack surface. `CLAUDE.md` describes a host manager that spawns binaries; it's intentionally a refusal. See [docs/EXTENSIONS.md](docs/EXTENSIONS.md).
- **Chrome APIs WebKit lacks are stand-ins.** `privacy`, `management`, `idle`, `downloads` and some events exist so Chrome-built extensions start, but nothing is changed or downloaded through them.
- **Extension notifications** are shown by macOS (it asks permission the first time) with the extension's name, text and up to two buttons; images, progress bars and `requireInteraction` aren't. Clicks, button clicks and dismissals reach the extension. A notification still showing keeps its extension's background able to receive them, so it may keep running until the notification is dismissed. Extensions added before this need to be added again (adding the same version offers Reinstall). Not shown when Lily runs outside an app bundle (`swift run`).
- **Compatibility mode (macOS 14–15.3)** runs extension page scripts only: no popups, backgrounds or most `chrome.*` APIs.
- **Extension audit is static.** Minified or obfuscated code can hide behavior; a `.crx` added from a file isn't signature-checked (there's no ID to check it against), unlike store downloads.
- **Ad blocking** skips scriptlets (`+js`), redirects and rules WebKit can't express exactly.
- **Separate logins** separate website data only: history, bookmarks, downloads and extensions (and their storage) are shared by all spaces.
- **Typed-text recovery** covers textareas and rich-text editors in the main frame: not single-line inputs (by choice), and not editors inside iframes. A field is recognized by its id, name or position; when a page generates new ids each load, restoring works only when it's unambiguous (one draft, one empty field).
- **Find in page** counts matches in the main frame's visible text, while WebKit searches every frame, so the count can differ on pages with iframes. It shows a count, not "3 of 12".
- **Link Scrolling** aligns panes by the fraction scrolled, which matches identical layouts exactly and similar documents approximately.
- **Paused panes** keep their memory (only CPU and rendering stop); the background-tab sleeper is what frees memory.
- **Assistant** traffic to a local Ollama is plain HTTP on this Mac (see [Security](#security)).
- **Importing** Safari, and Chrome on recent macOS, needs Full Disk Access for Lily.
- **Ad-hoc builds** can't read Lily's saved data after a rebuild (session, history, extension list: the Keychain key is tied to the build); signed builds keep it. For local builds, a free Apple Development certificate is enough: `CODESIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)" make app`.

## Releases

[`.github/workflows/dmg.yml`](.github/workflows/dmg.yml) builds and publishes DMGs. The version comes from [`VERSION`](VERSION) (`MAJOR.MINOR.PATCH`).

| Action | Result |
|---|---|
| Open a PR from `main` into `testing` | Tests run and a DMG is attached to the workflow run (**Actions → run → Artifacts**) |
| Merge it | Tag `vX.Y.Z-testing.N` and a GitHub pre-release with the DMG and its SHA-256 |
| Open a PR from `main` into `release` | The same build as a release candidate; the PR fails if `vX.Y.Z` already exists |
| Merge it | Annotated tag `vX.Y.Z` and a GitHub release (marked latest) with the DMG, its SHA-256 and generated notes |

To ship a release: bump `VERSION` on `main`, open a PR from `main` into `release`, check the DMG from the PR run, then merge.

Signing and notarization turn on when these repository secrets are set:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12 password |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarytool credentials (app-specific password) |

Without them, builds are ad-hoc signed and the first launch has to be approved manually.
