# Little Lily: design

Little Lily is a small, single-page window for a quick look at one link, like Arc's Little Arc. It's
where links from other apps (Mail, Slack, Notes…) open, so they don't pile up as tabs in your main
window. If the page turns out to be worth keeping, **Open in Lily** moves it into the main window,
as it is: same scroll position, same form input, same video time, no reload.

Status: **designed, not built.** This document is the plan the implementation follows.

## What it does

| | Little Lily | Main window |
|---|---|---|
| Content | one page | tabs, spaces, splits |
| Chrome | a slim title bar: site, lock, Open in Lily, Copy Link, close | sidebar, toolbar |
| Size | small (about 900 × 640), remembered | large, remembered |
| On close | the page is gone (it's in history) | tabs restored next launch |
| Session | never restored | restored |

**Opening one**
- Links from other apps open in Little Lily when *Settings → General → Open links from other apps in Little Lily* is on (default: on, as in Arc). Off: they open as tabs, as today.
- File → New Little Lily Window (⌥⌘N), which opens the command bar to type an address.
- A link's context menu → Open Link in Little Lily.
- ⌘K finds all of these, since they're menu commands.

**In the window**
- Browsing inside it stays in it: links navigate in place; a link that opens a new window (`target=_blank`) opens a tab in the main window, not another Little Lily.
- **Open in Lily** (⇧⌘O, and the title bar button; ⌘O stays Open File): the tab moves into the main window's current space, after the active tab, and becomes active; the Little Lily window closes.
- Copy Link (⇧⌘C), Find (⌘F), zoom, reload, back/forward, the Web Inspector: same commands as the main window.
- ⌘W closes it. (Not Esc: pages use it, and there's no reliable way to tell when they would.)

## Architecture

### A compact mode of the browser window, not a new window type

Little Lily is a `BrowserWindowController` with `style: .little`, holding a `TabStore` that never has
more than one tab. Everything that hangs off the window controller then works without new code:

- **Page routes** (`registerPageHandlers`): history, typed-text recovery, page metadata, selection,
  YouTube, ad blocking's procedural filters, Link Scrolling (unused), runtime errors.
- **Site settings, HTTPS-First, downloads, dialogs, permissions, crash recovery** (all in `Tab`).
- **Extensions**: the controller is already a `WKWebExtensionWindow`; Little Lily reports itself as
  window type `.popup` so extensions see it as a secondary window, and `tabs.query` finds its tab.
- **Find, Web Inspector, the command palette, menus and their validation** (responder chain).
- **Security**: the same `WebViewFactory`, content worlds, bridge checks and navigation policy.

What `style: .little` changes, in `BrowserWindowController`:
- `buildLayout()`: no sidebar split item; the content controller fills the window, under a
  SwiftUI `LittleLilyBar` (title-bar accessory) bound to the same `WindowModel`.
- `TabStore` rejects a second tab: `create` from a page (window.open, Open Link in New Tab) is
  routed to the main window instead (`tabDelegate` → `AppDelegate.mainWindow`).
- No session saving (`onSessionChange` not wired), no space UI, no split view (its menu items
  validate to off), no `TabSleeper` or `PaneFreezer` (a one-tab window is always the active tab).
- Window frame autosaved under its own name (`LilyLittleWindow`).

Private windows are unaffected; a link from another app never opens in a private window.

### The new capability: moving a live tab between windows

Open in Lily needs to move a `Tab`, with its `WKWebView` and page state, from one window's
`TabStore` to another's without tearing it down. Today a `Tab` is created and destroyed by one
store. Two `TabStore` additions:

```swift
/// Takes `id` out of this store without tearing it down (no `tearDown`, no recently-closed
/// entry), for handing to another window. Its split membership is dropped.
public func detach(_ id: UUID) -> Tab?

/// Adds a tab that came from another window: assigns it this store's current space and delegate,
/// inserts it after the active tab, activates it.
public func adopt(_ tab: Tab, activate: Bool = true)
```

`BrowserWindowController.moveTab(_:to:)` does detach → adopt and fixes up what belongs to the window:
- the IPC router: `Tab`'s bridge is built with the source window's `router`; the tab gets
  `rebind(router:)` so page messages reach the new window's handlers;
- the extension controller: `didCloseTab` for the old window, `didOpenTab` + `didActivateTab` for
  the new one (so extensions see a move, not a close);
- the content view: the web view is removed from the Little Lily content controller and shown by
  the main window's (`showTab`), the same `WKWebView` instance, so the page isn't reloaded;
- the data store: Little Lily uses the shared store (`space: nil`). Moving into a space with
  Separate logins calls `Tab.rebuildWebView()` (state restored, page reloaded on that space's
  cookies). That's the one case that reloads, and it's correct: the page must not keep the
  shared store's cookies inside an isolated space.

The same two methods later allow dragging a tab between main windows, and "Move Tab to New Window"
without a reload, which today opens a fresh tab instead.

### External links

`AppDelegate.application(_:open:)` decides:
- web URLs + preference on → `LittleLilyController` (one new window per link, cascaded; if a
  Little Lily window for the same URL is already open, it's brought forward);
- files, or preference off → the main window, as today.

Links clicked inside Lily never open Little Lily on their own.

### Files

| File | What |
|---|---|
| `Browser/BrowserWindowController.swift` | `Style` (`.regular`, `.little`), layout and wiring per style |
| `Browser/TabStore.swift` | `detach`, `adopt`, and the one-tab limit for `.little` |
| `Browser/Tab.swift` | `rebind(router:)` |
| `Browser/LittleLily.swift` | opening, Open in Lily, cascade and reuse of windows, the preference |
| `UI/LittleLilyBar.swift` | the slim title bar (site, lock, Open in Lily, Copy Link) |
| `App/MainMenu.swift`, `App/AppDelegate.swift` | New Little Lily Window, external-link routing |

### Resource use

A Little Lily window is one tab and one web content process, with no sidebar and no timers. When it
closes, the tab is torn down like a closed tab (the page is in history). Promoting it costs nothing:
the web view moves as is.

### Tests

- `TabStore`: `detach` keeps the tab alive and out of recently closed; `adopt` sets space,
  position and activation; a `.little` store refuses a second tab.
- Self-test: open a Little Lily window with a fixture page, type into a field and scroll, Open in
  Lily, then check the main window has the tab with the same web view (no reload: a counter in the
  page keeps its value), the typed text and the scroll position, and the Little window is gone.
- External links: preference on → a Little Lily window; off → a tab in the main window.

### Open questions

- Should a Little Lily window close when it loses focus after a while (Arc doesn't)? Default: no.
- Should Open in Lily ask which space when there are several? Default: the current one; the title
  bar button could get a menu of spaces later.
