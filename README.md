# ArcClone

A native macOS browser in the spirit of Arc: vertical tabs in a sidebar, spaces, split view, a command bar, and a local AI assistant that can summarize the page or YouTube video you're on and explain selected text.

ArcClone is written in Swift with AppKit and SwiftUI and renders pages with WebKit (`WKWebView`), the engine Safari uses. There is no Electron, no bundled Chromium and no Node; the only JavaScript is the set of scripts in `injections/` that run inside web pages. The assistant talks to [Ollama](https://ollama.com) on your Mac.

> **Status:** early development (0.x).

## Install

1. Download a DMG from [Releases](https://github.com/pwngoblin/ArcClone/releases), or from a workflow run's artifacts.
2. Open it and drag **ArcClone** to **Applications**.
3. Builds without a Developer ID signature are blocked on first launch: open **System Settings → Privacy & Security** and click **Open Anyway**.

**Requirements**
- macOS 14 Sonoma or later, Apple silicon or Intel. Web extensions need macOS 15.4 or later.
- For the assistant only: [Ollama](https://ollama.com) with at least one model (`ollama pull llama3.2`).

## Features

**Tabs and windows**
- A sidebar with pinned tabs as rounded tiles and regular tabs below. Drag to reorder; right-click for duplicate, pin, copy link, share, pause media, open in new window, split, move to another space, and close tab / others / below.
- **Spaces**: separate sets of tabs, each with a name, icon and color that tints the sidebar. Switch with a two-finger horizontal swipe on the sidebar, the switcher in the sidebar footer, or ⌥⌘] / ⌥⌘[.
- **Split view**: two side by side, two stacked, three columns, three rows, or a 2×2 grid. Click a pane to focus it. Each split appears in the sidebar as one pill arranged like the split, and you can keep several splits at once.
- **Command bar** (⌘T, ⌘L): opens addresses, searches with your chosen engine, and suggests open tabs and history.
- **Private windows** (⇧⌘N): in-memory website data that is never saved, no history, no extensions, and a request to macOS to keep the window out of screen capture.
- **Sleeping tabs**: background tabs unused for 15 minutes (configurable, 5 in Low Power Mode) unload their page to free memory and come back where you left off. Tabs playing media, using the camera or microphone, or in a visible split stay awake. Memory pressure from macOS puts eligible tabs to sleep immediately.
- Tabs, pinned tabs, spaces and opened files (*File → Open File…*) are restored on launch.

**Pages**
- **Site settings** per website (toolbar button or ⌥⌘,): zoom, appearance, JavaScript, ads, camera and microphone, and clearing the site's data.
- **Dark mode for websites** (⌥⌘D): use the site's own dark theme, or *Force Dark* to invert sites without one while keeping images and video natural.
- **Site security**: the lock next to the address shows whether the connection is secure (or mixes in insecure content), the certificate's subject, issuer and expiry with the system certificate viewer, your settings for the site, and whether it stores data.
- **Ad and tracker blocking** with WebKit content rules: a built-in list, YouTube ad skipping, and a toolbar shield to allow ads on a site. Filter lists can be turned on in Settings → Privacy: EasyList, EasyPrivacy, uBlock filters, uBlock filters – Privacy, Peter Lowe's list and AdGuard Annoyances. They're downloaded weekly and converted from Adblock Plus / uBlock Origin syntax, including exceptions, `$domain=`, `$important`, `$badfilter`, element hiding, and procedural filters (`:has-text()`, `:upward()`, `:style()` limited to layout properties) that run in the page. Scriptlets (`+js`), redirects and other filters that would run list-supplied code, or that WebKit can't express exactly, are skipped.
- **HTTPS-First**: `http://` addresses are tried over HTTPS first; falling back to HTTP asks you.
- **Downloads**: a progress ring and badge in the sidebar, and a popover with progress, time remaining, cancel, retry (resuming when possible) and Show in Finder.
- **Web extensions** (macOS 15.4+): Chrome, Firefox and Safari web extensions from a folder, .zip or Chrome Web Store .crx (Settings → Extensions). Each is audited before installing: anything that could load code from outside the extension is refused, and eval, telemetry calls and sensitive permissions are shown with every permission. The approved copy is pinned in the app's container, checked against its SHA-256 at every launch, and never updates on its own. Extensions can't reach ArcClone's page bridge. See [docs/EXTENSIONS.md](docs/EXTENSIONS.md).

**History**
- A History window (⌘Y) with time ranges, most-visited sites and search; a History list in the sidebar (clock button); recently visited pages in the History menu. Private windows are never recorded.

**Assistant** (⌘E)
- Ask about the current page, summarize a page or a YouTube video from its transcript (⇧⌘E), or explain selected text. Timestamps in answers jump to that point in the video.

**macOS integration**
- Native toolbar, standard menus (Services, Spelling and Grammar, Substitutions, Speech), printing, and a Settings window (⌘,) with General, Tabs, Appearance, Websites, Privacy, Extensions (macOS 15.4+) and Assistant panes.
- Can be the default browser; opens `http`/`https` links and HTML files.
- Handoff of the current tab to your other Apple devices.
- Haptic feedback on Force Touch trackpads for actions such as reordering, pinning, splitting, switching spaces and crossing the space-swipe threshold (Settings → General).
- Appearance: accent color, sidebar color and strength, a paper-like grain, and System / Light / Dark.
- Release DMGs are universal binaries (arm64 + x86_64).

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘T / ⌘L | New tab / edit the current address |
| ⌘N / ⇧⌘N | New window / new private window |
| ⌘W / ⇧⌘T | Close tab / reopen closed tab |
| ⌘1–⌘8, ⌘9 | Go to a tab / the last tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘D | Pin or unpin tab |
| ⌥⌘] / ⌥⌘[ | Next / previous space |
| ⌃⌘1–⌃⌘5 / ⌃⌘0 | Split view layouts / exit split view |
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
| ⌘, | Settings |

## Security

| Area | What ArcClone does |
|---|---|
| **Data at rest** | The session, history and site settings are encrypted with AES-GCM using a key in your Keychain (`…AfterFirstUnlockThisDeviceOnly`, with an access list that trusts only ArcClone), written owner-only (0600) with file protection and excluded from backups. Logs keep URLs private. *Clear Browsing Data* removes website data, the session, history and the assistant's context. |
| **Network** | HTTPS-First for page navigations. The app's own connections use TLS 1.2+ under App Transport Security. Ollama may use plain HTTP only on this Mac; a remote host must use HTTPS and can be pinned by SPKI SHA-256 (*Settings → Assistant*), checked after normal certificate validation. Websites use WebKit's TLS validation with no overrides. |
| **Sandbox** | App Sandbox with a minimal entitlement list ([`scripts/ArcClone.entitlements`](scripts/ArcClone.entitlements)), no temporary exceptions, no helper processes. Files are opened through the open panel and reopened with read-only security-scoped bookmarks. Downloads are quarantined. Opening another app through a link always asks first. |
| **Code integrity** | Hardened runtime with library validation, no JIT and no DYLD environment variables. Only system libraries are loaded and only the `/usr/lib/swift` rpath is kept. Packaged builds ignore developer environment overrides and check their own signature and resources at launch, refusing to run if modified. |
| **Pages and scripts** | Injected scripts run in an isolated WebKit content world that websites can't reach. Their messages are decoded into fixed schemas with size limits and must match the frame's real origin. Native code passes data to scripts as arguments, never by building JavaScript strings. JavaScript dialogs name the real origin and can be silenced. Pages can't navigate a tab to a `data:` URL. |
| **Other apps** | Copies made in private windows are marked so clipboard managers skip them. There is no AppleScript interface. Website data (cookies, storage, caches) is written by WebKit inside the app container: on macOS 14+ a Developer ID-signed build's container is protected from other apps, and *Clear cookies and website data when ArcClone quits* removes it. |
| **Release builds** | Stripped binaries (the dSYM is kept separately), no `get-task-allow`, Web Inspector off. |

[`scripts/verify-app.sh`](scripts/verify-app.sh) runs on every `make app` and in CI. It fails the build if the signature and sealed resources, hardened runtime, entitlement allowlist, load commands, Info.plist rules, symbol stripping or secret scan don't pass.

The assistant sends page text to Ollama over HTTP on this Mac. While Ollama isn't running, another local program could listen on its port, so use the assistant on a Mac you trust.

**Signing note:** ad-hoc builds store the encryption key per build, so the saved session doesn't survive an update; Developer ID builds keep it.

## Architecture

```
core/          Swift package: the app (AppKit + SwiftUI), tabs (WKWebView), page IPC, assistant, storage
injections/    JavaScript run inside web pages in an isolated content world: page metadata, text
               extraction, selection, YouTube transcripts and ad skipping, dark mode,
               procedural element hiding
scripts/       Packaging (bundle, icon, entitlements, DMG) and the security audit
.github/       CI, the DMG/release workflow, branch hygiene, the PR template
```

Injected scripts and native code exchange versioned JSON envelopes (`{ v, id, kind, type, payload }`) through `WKScriptMessageHandlerWithReply`, routed by `IPCRouter`.

## Development

Requires Xcode 16 or later (Swift 6).

```sh
make            # build core/
make run        # run the development build from the repository
make check      # Swift tests (what CI runs)
make test       # Swift tests, then the end-to-end self-test
make app        # build/ArcClone.app, then scripts/verify-app.sh
make dmg        # build/ArcClone-<version>.dmg
```

`make app` options: `UNIVERSAL=1` builds arm64 + x86_64, `VERSION` / `BUILD_NUMBER` override the version, and `CODESIGN_IDENTITY` signs with a certificate (ad-hoc otherwise).

`ArcClone --self-test` starts the app, exercises the injections, page events, native-to-page calls, history recording, encrypted storage and the assistant, prints a JSON report, and exits non-zero on failure. `ARCCLONE_SELFTEST_NETWORK=1` adds live checks of HTTPS-First and certificate pinning.

How to branch, open and merge pull requests, and cut releases is in [`CONTRIBUTING.md`](CONTRIBUTING.md).

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
