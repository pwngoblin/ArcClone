# ArcClone

A native macOS browser in the spirit of Arc: a vertical tab sidebar, pinned tabs, a command bar, and a local AI assistant that can summarize the page you're on, explain a selection, or answer questions about a YouTube video from its transcript.

The app is written in Swift with AppKit and SwiftUI and renders pages with WebKit (`WKWebView`), the same engine as Safari. It isn't Electron and doesn't bundle Chromium. The assistant runs entirely on your Mac through [Ollama](https://ollama.com).

> **Status:** early development (0.x). Expect rough edges.

## Install

1. Download the latest `ArcClone-*.dmg` (see [Releases](#releases)).
2. Open it and drag **ArcClone** to **Applications**.
3. If the build isn't notarized, macOS blocks the first launch. Open **System Settings → Privacy & Security** and click **Open Anyway**.

**Requirements**
- macOS 14 Sonoma or later, Apple silicon or Intel
- [Node.js](https://nodejs.org) 20+ for the assistant, installed with Homebrew, nvm or Volta (`brew install node`). The sandbox can only find Node in those locations.
- [Ollama](https://ollama.com) with at least one model pulled for the assistant (`ollama pull llama3.2`)

Browsing works without Node or Ollama. Only the assistant needs them.

## Using it

| Shortcut | Action |
|---|---|
| ⌘T / ⌘L | New tab / open location |
| ⌘W / ⇧⌘T | Close tab / reopen closed tab |
| ⌘1–⌘8, ⌘9 | Jump to a tab, or the last tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘D | Pin or unpin tab |
| ⌘S | Toggle sidebar |
| ⌘E / ⇧⌘E | Toggle assistant / summarize page |
| ⌘[ / ⌘] | Back / forward |
| ⌘F, ⌘G, ⇧⌘G | Find, next, previous |
| ⌘P | Print |
| ⌘, | Settings |

Under **Settings** you can choose a search engine and homepage, make ArcClone your default browser, and set the Ollama host and model.

## Native macOS integration

- Standard AppKit menus: Services, Spelling and Grammar, Substitutions, Speech, Dictation, Emoji & Symbols, and a searchable Help menu
- Full-height sidebar with system vibrancy that follows light/dark mode and window focus
- A toolbar-style Settings window built with SwiftUI
- Can be set as the default browser, and opens `http`/`https` links and `.html` files
- Handoff: continue the active tab in Safari on your iPhone or iPad
- Native printing, find-in-page, and pinch-to-zoom
- Window size and sidebar width are saved, and your tabs are restored on relaunch
- Universal binary (arm64 + x86_64), App Sandbox and hardened runtime ([entitlements](scripts/ArcClone.entitlements))

## Architecture

```
core/           Swift package: AppKit app, WKWebView tabs, native IPC router
injections/     JavaScript run in every page, in an isolated WebKit content world
ui/             Sidebar UI (Svelte) loaded from the app bundle via arc-ui://
agent-bridge/   Node process that talks JSON-RPC (stdio) to core and HTTP to Ollama
scripts/        Packaging: .app bundle, icon, entitlements, DMG
```

Every message between web content and native code uses one versioned JSON envelope, `{ v, id, kind, type, payload }`, sent through `WKScriptMessageHandlerWithReply` and routed by `IPCRouter`.

- Each IPC route declares whether the **chrome** (sidebar UI) or **page** scripts (injections) may call it. Calls from any other source are rejected.
- Page scripts run in the `ArcInjections` content world, so websites can't see or call the bridge.
- The sidebar can only load from `arc-ui://`. The scheme handler blocks path traversal.
- Native code pushes events to the sidebar with `callAsyncJavaScript`. Arguments are passed separately, never interpolated into JS source.

The sidebar is planned to move to SwiftUI.

## Development

You need Xcode 16 or later (Swift 6) and Node 20 or later.

```sh
make            # build ui/ and core/
make run        # run the dev build from the repo
make test       # agent-bridge, ui and Swift tests, then the end-to-end self-test
make app        # build/ArcClone.app
make dmg        # build/ArcClone-<version>.dmg
```

`make app` options: `UNIVERSAL=1` builds arm64 + x86_64, `VERSION`/`BUILD_NUMBER` override the version, and `CODESIGN_IDENTITY` signs with a real certificate (the default is ad-hoc).

`ArcClone --self-test` starts the real app, runs every IPC path (sidebar handshake, injections, page events, native→page calls, agent bridge), prints a JSON report, and exits non-zero on failure.

For quick UI work, `cd ui && npm run dev` serves the sidebar in a browser against a mock native layer.

## Releases

DMGs are built by GitHub Actions ([`.github/workflows/dmg.yml`](.github/workflows/dmg.yml)):

| Open a pull request into | You get |
|---|---|
| `testing` | a test build: `ArcClone-<version>-testing.<run>-<sha>.dmg`, kept 14 days |
| `release` | a release candidate: `ArcClone-<version>-release.<run>-<sha>.dmg`, kept 90 days |

Every run tests the project, builds a universal app, and attaches the DMG to the workflow run (**Actions → run → Artifacts**). The marketing version comes from [`VERSION`](VERSION).

**Signing and notarization** are optional and turn on when these repository secrets are set:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12 password |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarytool credentials (app-specific password) |

Without them, builds are ad-hoc signed and users have to approve the first launch manually.
