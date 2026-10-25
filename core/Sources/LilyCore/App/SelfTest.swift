import AppKit
import WebKit
import SQLite3

/// `Lily --self-test`: boots the real app, loads a fixture page and exercises every IPC path
/// (chrome UI handshake, injection runtime, page events, native->page invoke, assistant),
/// prints a JSON report to stdout and exits non-zero on failure.
@MainActor
enum SelfTest {
    static let fixture = """
    <!doctype html><html lang="en"><head><title>Lily Self Test</title>
    <meta name="description" content="Fixture page for the self test">
    <link rel="icon" href="/icon.svg"></head>
    <body style="overflow: hidden"><nav><a href="/a">Home</a><a href="/b">About</a></nav>
    <article><h1>Self test heading</h1>
    <p>The quick brown fox jumps over the lazy dog. This paragraph exists so that the readable content extractor has enough text to score, with commas, clauses, and sentences.</p>
    <p>A second paragraph adds more weight to the article container, making it the obvious choice for extraction over the navigation links above.</p>
    <h2>Details</h2><ul><li>First item</li><li>Second item</li></ul></article>
    <aside class="card" id="sponsored-card"><span>Sponsored</span></aside><aside class="card" id="plain-card"><span>Related</span></aside>
    <footer>Footer text</footer></body></html>
    """

    static func run(window: BrowserWindowController, assistant: Assistant) {
        Task { @MainActor in
            var report: [String: JSONValue] = [:]
            var failures: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: JSONValue = .null) {
                report[name] = ["ok": .bool(ok), "detail": detail]
                if !ok { failures.append(name) }
            }

            check("window.ready", await waitUntil(10) { window.window?.isVisible == true })
            // Pages render (scroll, animation frames) only in a window that's on screen. When
            // another app or Space covers Lily, checks that measure rendering say so instead of
            // failing for a reason that isn't Lily's.
            @MainActor func notOnScreen() -> String? {
                window.window?.occlusionState.contains(.visible) == true ? nil : "window not on screen"
            }

            // In-page (procedural) filters for the fixture's site, as a downloaded list would provide.
            window.factory.adBlocker?.useProceduralFilters(["selftest.lily.test": [
                ProceduralFilter(selector: "aside.card span", steps: [.init(type: "has-text", arg: "/^sponsored$/i"), .init(type: "upward", arg: "1")]),
                ProceduralFilter(selector: "body", steps: [], style: "overflow: auto"),
            ]])
            let tab = window.tabs.create(url: nil)
            tab.webView.loadHTMLString(fixture, baseURL: URL(string: "https://selftest.lily.test/article")!)
            let titled = await waitUntil(10) {
                tab.title == "Lily Self Test" && tab.faviconURL != nil && window.model.tabs.contains { $0.title == "Lily Self Test" }
            }
            check("history recorded", window.history?.visits.first?.url.host == "selftest.lily.test",
                  JSONValue(window.history?.visits.first?.url.absoluteString))
            check("page.didChange event", titled, ["title": .string(tab.title), "favicon": JSONValue(tab.faviconURL?.absoluteString)])

            do {
                let ping = try await tab.callInjection("runtime.ping")
                let handlers = ping["handlers"]?.array?.compactMap(\.string) ?? []
                check("runtime.ping", ping["pong"]?.bool == true && handlers.contains("dom.extract"), ping)
                // The YouTube module is host-restricted and must not be present here.
                check("host-guard", !handlers.contains("youtube.transcript"), .array(handlers.map(JSONValue.string)))
            } catch { check("runtime.ping", false, .string("\(error)")) }

            do {
                let extract = try await tab.callInjection("dom.extract")
                let text = extract["text"]?.string ?? ""
                check("dom.extract", text.contains("quick brown fox") && text.contains("# Self test heading") && !text.contains("Footer text"),
                      ["wordCount": extract["wordCount"] ?? .null, "outline": extract["outline"] ?? .null, "preview": .string(String(text.prefix(160)))])
            } catch { check("dom.extract", false, .string("\(error)")) }

            do {
                _ = try await tab.callInjection("no.such.handler")
                check("unknown injection rejected", false)
            } catch let e as IPCError { check("unknown injection rejected", e.code == "unknown_handler", .string(e.code)) }
            catch { check("unknown injection rejected", false, .string("\(error)")) }

            var cosmetic: [String] = []
            for _ in 0..<50 {
                let state = try? await tab.webView.evaluateJavaScript("""
                [getComputedStyle(document.getElementById('sponsored-card')).display, getComputedStyle(document.getElementById('plain-card')).display,
                 getComputedStyle(document.body).overflow].join(',')
                """)
                cosmetic = (state as? String)?.components(separatedBy: ",") ?? []
                if cosmetic == ["none", "block", "auto"] { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            check("procedural filters", cosmetic == ["none", "block", "auto"], .array(cosmetic.map(JSONValue.string)))

            // Download animation: the icon flies in an overlay above every other view, from inside
            // the window to the sidebar's downloads button.
            try? await Task.sleep(for: .milliseconds(300))
            if let reason = window.downloadFlightSkipReason {
                check("download animation", true, ["skipped": .string(reason)])
            } else {
                window.animateDownloadFlight()
                let overlay = window.window?.contentView?.subviews.last as? AnimationOverlayView
                let flight = overlay?.layer?.sublayers?.first { $0.animation(forKey: "flight") != nil }
                let path = ((flight?.animation(forKey: "flight") as? CAAnimationGroup)?.animations?.first as? CAKeyframeAnimation)?.path
                let bounds = overlay?.bounds ?? .zero
                let ends = path.map { [$0.currentPoint, flight?.position ?? .zero] } ?? []
                check("download animation", overlay != nil && flight != nil && !ends.isEmpty && ends.allSatisfy(bounds.contains),
                      ["overlayOnTop": .bool(overlay != nil), "animating": .bool(flight != nil),
                       "end": JSONValue(ends.first.map { "\(Int($0.x)),\(Int($0.y))" }), "bounds": .string("\(Int(bounds.width))x\(Int(bounds.height))")])
            }

            // Form recovery: typing into a long field keeps a draft (never a card field, never the
            // query string), a reload offers it back, and Restore fills the empty field.
            let compose = """
            <!doctype html><title>Compose</title><form>
            <textarea id="body"></textarea><textarea id="card" autocomplete="cc-number"></textarea></form>
            """
            let composeURL = URL(string: "https://selftest.lily.test/compose?session=secret")!
            let formTab = window.tabs.create(url: nil)
            formTab.webView.loadHTMLString(compose, baseURL: composeURL)
            _ = await waitUntil(10) { formTab.title == "Compose" }
            let typed = "A long reply that would be painful to lose when the page crashes."
            _ = try? await formTab.webView.evaluateJavaScript("""
            for (const [id, text] of [['body', \(String(reflecting: typed))], ['card', '4111 1111 1111 1111 1111']]) {
              const field = document.getElementById(id); field.value = text;
              field.dispatchEvent(new InputEvent('input', { bubbles: true }));
            }
            """)
            let saved = await waitUntil(5) { window.formDrafts?.drafts(for: composeURL).isEmpty == false }
            let drafts = window.formDrafts?.drafts(for: composeURL) ?? []
            formTab.webView.loadHTMLString(compose, baseURL: composeURL)
            let offered = await waitUntil(10) { window.model.toast?.action?.title == "Restore" }
            window.restoreTypedText(nil)
            var refilled = ""
            for _ in 0..<50 {
                refilled = (try? await formTab.webView.evaluateJavaScript("document.getElementById('body').value")) as? String ?? ""
                if refilled == typed { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            check("form recovery", saved && drafts.map(\.field) == ["textarea#body"] && drafts.first?.page == "https://selftest.lily.test/compose"
                  && offered && refilled == typed,
                  ["fields": .array(drafts.map { .string($0.field) }), "offered": .bool(offered), "restored": .bool(refilled == typed)])
            window.formDrafts?.removeAll()
            window.tabs.close(formTab.id)

            // Link Scrolling: scrolling one pane of a linked split moves the other to the same
            // fraction of its (different) length; unlinked, it stays put.
            func longPage(_ height: Int) -> String { "<!doctype html><title>Long \(height)</title><div style='height:\(height)px'></div>" }
            let left = window.tabs.create(url: nil)
            left.webView.loadHTMLString(longPage(6000), baseURL: URL(string: "https://selftest.lily.test/left")!)
            let right = window.tabs.create(url: nil, activate: false)
            right.webView.loadHTMLString(longPage(12000), baseURL: URL(string: "https://selftest.lily.test/right")!)
            _ = await waitUntil(10) { left.title == "Long 6000" && right.title == "Long 12000" }
            window.tabs.activate(left.id)
            window.tabs.makeSplit(.twoColumns, with: [right.id])
            window.toggleLinkScrolling(nil)
            try? await Task.sleep(for: .milliseconds(300))
            @MainActor func fraction(_ tab: Tab) async -> Double {
                let value = try? await tab.webView.evaluateJavaScript("scrollY / (document.scrollingElement.scrollHeight - innerHeight)")
                return (value as? Double) ?? (value as? NSNumber)?.doubleValue ?? -1
            }
            _ = try? await left.webView.evaluateJavaScript("scrollTo(0, 0.75 * (document.scrollingElement.scrollHeight - innerHeight))")
            var followed = -1.0
            for _ in 0..<30 {
                followed = await fraction(right)
                if abs(followed - 0.75) < 0.02 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            window.toggleLinkScrolling(nil)
            try? await Task.sleep(for: .milliseconds(300))
            _ = try? await left.webView.evaluateJavaScript("scrollTo(0, 0)")
            try? await Task.sleep(for: .milliseconds(500))
            let stayed = await fraction(right)
            if let reason = notOnScreen() {
                check("link scrolling", true, ["skipped": .string(reason)])
            } else {
                check("link scrolling", abs(followed - 0.75) < 0.02 && abs(stayed - followed) < 0.02,
                      ["followed": .number(followed), "afterUnlink": .number(stayed)])
            }
            window.tabs.exitSplit()
            window.tabs.close(left.id)
            window.tabs.close(right.id)

            // Pausing idle split panes: a paused pane's page stops running (animation frames), shows
            // a picture instead, and runs again when resumed.
            let busyPage = "<!doctype html><title>Ticker</title><script>window.frames_ = 0; (function tick() { frames_++; requestAnimationFrame(tick); })();</script>"
            let focusedPane = window.tabs.create(url: nil)
            focusedPane.webView.loadHTMLString("<!doctype html><title>Focused</title>", baseURL: URL(string: "https://selftest.lily.test/focused")!)
            let idlePane = window.tabs.create(url: nil, activate: false)
            idlePane.webView.loadHTMLString(busyPage, baseURL: URL(string: "https://selftest.lily.test/ticker")!)
            _ = await waitUntil(10) { focusedPane.title == "Focused" && idlePane.title == "Ticker" }
            window.tabs.activate(focusedPane.id)
            window.tabs.makeSplit(.twoColumns, with: [idlePane.id])
            @MainActor func frames() async -> Double {
                let value = try? await idlePane.webView.evaluateJavaScript("frames_")
                return (value as? Double) ?? (value as? NSNumber)?.doubleValue ?? -1
            }
            // Animation frames only run in a visible window: measure with Lily in front, so another
            // window covering it doesn't read as "paused" (it did, once, on a busy desktop).
            NSApp.activate()
            window.window?.makeKeyAndOrderFront(nil)
            _ = await waitUntil(3) { window.window?.isKeyWindow == true && window.window?.occlusionState.contains(.visible) == true }
            try? await Task.sleep(for: .milliseconds(300))
            let start = await frames()
            try? await Task.sleep(for: .milliseconds(1500))
            let running = await frames() - start
            await window.freezeIdlePanes(threshold: 0)
            let paused = window.contentController.isFrozen(idlePane.id) && idlePane.webView.isHidden
            let before = await frames()
            try? await Task.sleep(for: .milliseconds(1500))
            window.contentController.thawAll()
            let whilePaused = await frames() - before
            let resumedFrames = await frames()
            try? await Task.sleep(for: .milliseconds(500))
            let resumed = await frames() > resumedFrames
            if let reason = notOnScreen(), running < 20 {
                check("pause idle panes", paused && idlePane.webView.isHidden == false, ["skipped": .string(reason), "paused": .bool(paused)])
            } else {
                check("pause idle panes", paused && running >= 20 && whilePaused <= max(5, running * 0.1) && resumed && !idlePane.webView.isHidden,
                      ["framesRunning": .number(running), "framesWhilePaused": .number(whilePaused), "paused": .bool(paused), "resumed": .bool(resumed)])
            }
            window.tabs.exitSplit()
            window.tabs.close(focusedPane.id)
            window.tabs.close(idlePane.id)

            // Find (⌘F): Edit → Find opens the bar over the active page; WebKit finds the text and
            // the count is right; a missing word says so; Done closes it.
            func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
                let item = NSMenuItem(title: "", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "")
                item.tag = action.rawValue
                return item
            }
            window.tabs.activate(tab.id)
            let canFind = window.validateMenuItem(finderItem(.showFindInterface))
            window.performTextFinderAction(finderItem(.showFindInterface))
            let barShown = window.contentController.isFindBarShown
            window.find.query = "PARAGRAPH" // case-insensitive; the fixture has it twice
            let counted = await waitUntil(5) { window.find.found == true && window.find.matches == 2 }
            window.find.query = "no such words here"
            let missing = await waitUntil(5) { window.find.found == false }
            window.performTextFinderAction(finderItem(.hideFindInterface))
            check("find in page", canFind && barShown && counted && missing && !window.contentController.isFindBarShown,
                  ["validates": .bool(canFind), "shown": .bool(barShown), "matches": .number(Double(window.find.matches ?? -1)),
                   "found": .bool(counted), "notFound": .bool(missing)])

            // Tab drag and drop: a dragged tab carries its id inside the app (and its address for
            // other apps); dropping it on a pinned tile pins it, between rows unpins it, on a space
            // moves it there; links open where they're dropped, and only web links.
            let dragStore = window.tabs
            let pinned = dragStore.create(url: URL(string: "https://selftest.lily.test/pinned")!)
            dragStore.setPinned(pinned.id, true)
            let dragged = dragStore.create(url: URL(string: "https://selftest.lily.test/dragged")!)
            window.model.refresh(from: dragStore)
            let item = window.model.tabs.first { $0.id == dragged.id }
            var roundTrip = false, exportsURL = false
            if let item {
                let provider = TabDrag.provider(for: item)
                exportsURL = provider.canLoadObject(ofClass: URL.self)
                if case .tab(let id)? = await TabDrag.load([provider]) { roundTrip = id == dragged.id }
            }
            let pinnedByDrop = window.model.dropOnPinned(.tab(dragged.id), before: pinned.id) && dragged.isPinned
                && dragStore.tabs.firstIndex(of: dragged)! < dragStore.tabs.firstIndex(of: pinned)!
            window.model.dropInList(.tab(dragged.id), atRow: 0)
            let unpinnedByDrop = !dragged.isPinned
            let away = dragStore.addSpace(name: "Drop Target", symbol: "star.fill", color: "#0A84FF", activate: false)
            let movedToSpace = window.model.dropOnSpace(.tab(dragged.id), space: away.id) && dragged.spaceID == away.id
            let tabCount = dragStore.tabs.count
            let linkInSpace = window.model.dropOnSpace(.link(URL(string: "https://selftest.lily.test/link")!), space: away.id)
                && dragStore.tabs.count == tabCount + 1 && dragStore.tabs.last?.spaceID == away.id && dragStore.tabs.last?.hasWebView == false
            let scriptRefused = !window.model.dropOnSpace(.link(URL(string: "javascript:alert(1)")!), space: away.id)
            check("tab drag and drop", roundTrip && exportsURL && pinnedByDrop && unpinnedByDrop && movedToSpace && linkInSpace && scriptRefused,
                  ["roundTrip": .bool(roundTrip), "exportsURL": .bool(exportsURL), "pinned": .bool(pinnedByDrop), "unpinned": .bool(unpinnedByDrop),
                   "movedToSpace": .bool(movedToSpace), "linkOpensInSpace": .bool(linkInSpace), "scriptLinkRefused": .bool(scriptRefused)])
            dragStore.deleteSpace(away.id)
            dragStore.close(pinned.id)

            // Pinned tiles are a native collection view: the tiles are on screen, an AppKit drag's
            // pasteboard reads back as the tab, and dropping a tile further right lands exactly in
            // the gap shown (1 before 3 → 2, 1, 3).
            let tiles = (1...3).map { n -> Tab in
                let tab = dragStore.create(url: URL(string: "https://selftest.lily.test/pin\(n)")!, activate: false)
                dragStore.setPinned(tab.id, true)
                return tab
            }
            window.model.refresh(from: dragStore)
            try? await Task.sleep(for: .milliseconds(400))
            @MainActor func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let grid = window.window?.contentView.flatMap { views($0).compactMap { $0 as? NSCollectionView }.first }
            let shown = grid?.numberOfItems(inSection: 0) ?? -1
            let board = NSPasteboard(name: NSPasteboard.Name("dev.lily.selftest.drag"))
            board.clearContents()
            var appKitRoundTrip = false
            if let first = window.model.tabs.first(where: { $0.id == tiles[0].id }) {
                board.writeObjects([TabDrag.pasteboardItem(for: first)])
                if case .tab(let id)? = TabDrag.read(board) { appKitRoundTrip = id == tiles[0].id }
            }
            _ = window.model.dropOnPinned(.tab(tiles[0].id), before: tiles[2].id)
            let pinnedOrder = dragStore.tabs.filter(\.isPinned).map(\.id)
            let reordered = pinnedOrder == [tiles[1].id, tiles[0].id, tiles[2].id]
            check("native pinned tiles", shown == 3 && appKitRoundTrip && reordered,
                  ["tilesShown": .number(Double(shown)), "pasteboardRoundTrip": .bool(appKitRoundTrip), "dropsInGap": .bool(reordered)])
            tiles.forEach { dragStore.close($0.id) }
            board.releaseGlobally()

            // Web developer features: open pages follow the setting (inspectable, Inspect Element),
            // and the Develop menu is shown only with it on.
            let inspectorOn = WebInspector.isEnabled
            let page = tab.webView
            let extras = page.configuration.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:"))
                ? page.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool : inspectorOn
            let developMenuShown = NSApp.mainMenu?.item(withTitle: MainMenu.developMenuTitle)?.isHidden == false
            check("web inspector", page.isInspectable == inspectorOn && extras == inspectorOn && developMenuShown == inspectorOn
                  && (!inspectorOn || WebInspector.canShow(for: page)),
                  ["enabled": .bool(inspectorOn), "inspectable": .bool(page.isInspectable), "inspectElement": .bool(extras ?? false),
                   "developMenu": .bool(developMenuShown), "canShow": .bool(WebInspector.canShow(for: page))])

            // The menu bar: no items a browser doesn't need, and the shortcuts moved into submenus
            // still work (⌘1 goes to the first tab).
            func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
            if let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu { edit.delegate?.menuNeedsUpdate?(edit) }
            let all = NSApp.mainMenu.map(items) ?? []
            let removed = all.filter { item in
                [#selector(NSApplication.orderFrontCharacterPalette(_:)), NSSelectorFromString("startDictation:"),
                 #selector(NSTextView.startSpeaking(_:)), #selector(NSText.checkSpelling(_:)),
                 #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), NSSelectorFromString("toggleTabBar:")].contains(item.action)
            }.map(\.title)
            let importItems = all.filter { $0.action == #selector(AppDelegate.showMigration(_:)) }.count
            let firstTabKey = all.first { $0.action == #selector(BrowserWindowController.selectTabByNumber(_:)) && $0.tag == 1 }
            check("menu bar", removed.isEmpty && importItems == 1 && firstTabKey?.keyEquivalent == "1" && firstTabKey?.menu?.title == "Go to Tab",
                  ["unwanted": .array(removed.map(JSONValue.string)), "importItems": .number(Double(importItems))])

            // Little Lily: a one-page window; Open in Lily moves the live page into the main window
            // (same web view, no reload: the page's load stamp, typed text and scroll position
            // survive), the small window closes, and the page's messages reach the main window.
            let little = BrowserWindowController(factory: window.factory, assistant: assistant, history: window.history, style: .little)
            little.mainWindow = { window }
            little.showWindow(nil)
            let littlePage = little.tabs.create(url: nil)
            littlePage.webView.loadHTMLString("""
                <!doctype html><title>Little</title><script>window.stamp = Math.random();</script>
                <textarea id="note"></textarea><div style="height:4000px"></div>
                """, baseURL: URL(string: "https://selftest.lily.test/little")!)
            _ = await waitUntil(10) { littlePage.title == "Little" }
            _ = try? await littlePage.webView.evaluateJavaScript("document.getElementById('note').value = 'kept while moving'; scrollTo(0, 900);")
            let stamp = try? await littlePage.webView.evaluateJavaScript("String(window.stamp)") as? String
            let pageView = littlePage.webView
            var littleType = false
            if #available(macOS 15.4, *), let controller = window.extensionController as? WKWebExtensionController,
               let context = controller.extensionContexts.first {
                littleType = little.windowType(for: context) == .popup
            } else { littleType = little.isLittle }
            let canMove = little.validateMenuItem(NSMenuItem(title: "", action: #selector(BrowserWindowController.openInLily(_:)), keyEquivalent: ""))
            let mainHidesIt: Bool = {
                let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.openInLily(_:)), keyEquivalent: "")
                return !window.validateMenuItem(item) && item.isHidden
            }()
            little.openInLily(nil)
            let moved = window.tabs.active === littlePage && littlePage.webView === pageView && little.tabs.tabs.isEmpty
            let closed = await waitUntil(3) { little.window?.isVisible == false }
            let sameStamp = (try? await littlePage.webView.evaluateJavaScript("String(window.stamp)") as? String) == stamp && stamp != nil
            let kept = (try? await littlePage.webView.evaluateJavaScript("document.getElementById('note').value + '|' + Math.round(scrollY)") as? String)
            _ = try? await littlePage.webView.evaluateJavaScript("document.title = 'Moved'")
            let routed = await waitUntil(5) { littlePage.title == "Moved" && window.model.tabs.contains { $0.title == "Moved" } }
            check("little lily", moved && closed && sameStamp && kept == "kept while moving|900" && routed && canMove && mainHidesIt && littleType,
                  ["sameWebView": .bool(moved), "littleClosed": .bool(closed), "notReloaded": .bool(sameStamp),
                   "textAndScroll": JSONValue(kept), "messagesReachMain": .bool(routed), "menu": .bool(canMove && mainHidesIt)])
            window.tabs.close(littlePage.id)
            // Link tracking protection: a clicked link's click and campaign identifiers are gone
            // from the address the tab goes to; its other parameters stay.
            let trackedTab = window.tabs.create(url: nil)
            trackedTab.webView.loadHTMLString("""
                <!doctype html><title>Links</title>
                <a id="go" href="https://selftest.lily.test/landing?id=7&utm_source=newsletter&fbclid=IwAR123">go</a>
                """, baseURL: URL(string: "https://selftest.lily.test/links")!)
            _ = await waitUntil(10) { trackedTab.title == "Links" }
            _ = try? await trackedTab.webView.evaluateJavaScript("document.getElementById('go').click()")
            _ = await waitUntil(5) { trackedTab.webView.url?.path == "/landing" }
            let landed = trackedTab.webView.url?.absoluteString ?? ""
            check("link tracking protection", landed == "https://selftest.lily.test/landing?id=7",
                  ["navigatedTo": .string(landed)])
            window.tabs.close(trackedTab.id)

            // The user agent pages see is this Mac's Safari's, so Lily blends in.
            let agent = (try? await tab.webView.evaluateJavaScript("navigator.userAgent") as? String) ?? ""
            check("user agent matches Safari", agent.hasSuffix(window.factory.applicationNameForUserAgent) && !agent.contains("Lily")
                  && agent.contains("AppleWebKit/605.1.15"), ["userAgent": .string(agent)])

            // Handoff, receiving: a page continued from another device opens as the active tab of
            // the main window (trackers removed as for any opened link), through the selector
            // AppKit calls.
            let continuedSelector = NSSelectorFromString("application:continueUserActivity:restorationHandler:")
            let answers = (NSApp.delegate as AnyObject?)?.responds(to: continuedSelector) == true
            var continued = false
            if let app = NSApp.delegate as? AppDelegate {
                let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
                activity.webpageURL = URL(string: "https://selftest.lily.test/continued?ref=phone&utm_source=handoff")!
                let accepted = app.application(NSApp, continue: activity) { _ in }
                let arrived = await waitUntil(5) { window.tabs.active?.url?.path == "/continued" }
                continued = accepted && arrived
            }
            let opened = window.tabs.active?.url?.absoluteString ?? ""
            check("handoff continue", answers && continued && opened == "https://selftest.lily.test/continued?ref=phone",
                  ["delegateAnswers": .bool(answers), "opened": .string(opened)])
            if continued, let id = window.tabs.activeID { window.tabs.close(id) }

            // ⌘K reads the live menus: browser commands validate through the window's responder
            // chain, text-editing commands and the palette itself stay out.
            let palette = PaletteCommands.all(in: window.model).map(\.title)
            // (Titles are as validation leaves them: "Toggle Sidebar" reads "Hide Sidebar" while it's shown.)
            check("command palette", ["New Tab", "Reload Page", "Pin Tab", "Two Side by Side", "Hide Sidebar", "Find…"].allSatisfy(palette.contains)
                  && !palette.contains("Copy") && !palette.contains("Command Palette…"),
                  ["count": .number(Double(palette.count)), "sample": .array(palette.prefix(8).map(JSONValue.string))])

            // Lily's own pages run without page JavaScript, keep the tab's address and stay out of history.
            let internalTab = window.tabs.create(url: nil, activate: false)
            internalTab.showInternalPage("<!doctype html><title>internal</title><script>document.title = 'scripts ran'</script>", for: nil)
            var internalTitle = ""
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                internalTitle = (try? await internalTab.webView.evaluateJavaScript("document.title")) as? String ?? ""
                if !internalTitle.isEmpty { break }
            }
            let recorded = window.history?.visits.contains { ErrorPage.isInternal($0.url) } ?? false
            check("internal pages without scripts", internalTitle == "internal" && !recorded && !ErrorPage.isInternal(internalTab.url),
                  ["title": .string(internalTitle), "recorded": .bool(recorded)])
            window.tabs.close(internalTab.id)

            // Browser import inside the sandbox: a Chromium (Dia-style) profile with a WAL-mode History
            // database, built in the container, found, counted and read through the private copy.
            let migration = await Self.migrationProbe()
            check("migration in sandbox", migration["ok"]?.bool == true, migration)

            // Page-world scripts must not be able to reach the native bridge.
            let leaked = try? await tab.webView.evaluateJavaScript("typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.arc)")
            check("page world isolated", (leaked as? String) == "undefined", JSONValue(leaked as? String))

            // Ollama itself is optional (CI has none); the assistant must answer health without failing.
            let health = await assistant.health()
            check("assistant", health["ollama"]?["reachable"]?.bool != nil, health)

            // The session must round-trip through the real Keychain key and never hit disk in plaintext.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = SessionStore(directory: dir)
            let sample = SessionStore.Session(tabs: [.init(url: URL(string: "https://selftest.lily.test/?token=s3cret")!, title: "T", pinned: false)],
                                              activeIndex: 0)
            await store.save(sample)
            let onDisk = (try? Data(contentsOf: dir.appendingPathComponent("session.sealed"))) ?? Data()
            let restored = await store.load()
            check("session encrypted at rest", restored == sample && !onDisk.isEmpty && onDisk.range(of: Data("s3cret".utf8)) == nil,
                  ["bytes": JSONValue(onDisk.count)])

            if #available(macOS 15.4, *) {
                let popup = await Self.extensionPopupProbe(window: window, tab: tab)
                check("extension popup", popup["ok"]?.bool == true, popup)
                check("extension page in a tab", popup["page"]?["ok"]?.bool == true, popup["page"] ?? .null)
            }

            // Optional live HTTPS-First check (needs network): LILY_SELFTEST_NETWORK=1
            if ProcessInfo.processInfo.environment["LILY_SELFTEST_NETWORK"] != nil {
                let web = window.tabs.create(url: URL(string: "http://example.com/"))
                let upgraded = await waitUntil(20) { web.url?.scheme == "https" && !web.isLoading }
                check("https-first upgrade", upgraded, JSONValue(web.url?.absoluteString))

                // Pinning: the real key must pass, a wrong pin must be refused.
                let site = URL(string: "https://example.com/")!
                let pins = (try? await CertificatePinning.currentPins(for: site)) ?? []
                func fetch(_ pins: Set<String>) async -> Bool {
                    let session = URLSession(configuration: .ephemeral, delegate: PinningSessionDelegate(pins: pins), delegateQueue: nil)
                    defer { session.finishTasksAndInvalidate() }
                    return (try? await session.data(from: site)) != nil
                }
                let pinnedOK = !pins.isEmpty ? await fetch(Set(pins.prefix(1))) : false
                let wrongRefused = !(await fetch([Data(repeating: 0, count: 32).base64EncodedString()]))
                check("certificate pinning", pinnedOK && wrongRefused, ["pins": JSONValue(pins.count), "pinnedOK": .bool(pinnedOK), "wrongRefused": .bool(wrongRefused)])
            }

            // Optional live check against YouTube (needs network): LILY_SELFTEST_YOUTUBE=<videoId>
            if let videoID = ProcessInfo.processInfo.environment["LILY_SELFTEST_YOUTUBE"] {
                let yt = window.tabs.create(url: URL(string: "https://www.youtube.com/watch?v=\(videoID)"))
                let detected = await waitUntil(25) { yt.youtubeVideoID == videoID }
                check("youtube.videoChanged", detected, JSONValue(yt.youtubeVideoID))
                do {
                    let t = try await yt.callInjection("youtube.transcript", [:], timeout: 40)
                    let count = t["segments"]?.array?.count ?? 0
                    check("youtube.transcript", count > 5, ["source": t["source"] ?? .null, "segments": JSONValue(count),
                                                             "language": t["language"] ?? .null, "title": t["title"] ?? .null,
                                                             "preview": .string(String((t["text"]?.string ?? "").prefix(200)))])
                } catch { check("youtube.transcript", false, .string("\(error)")) }
            }

            if let dir = ProcessInfo.processInfo.environment["LILY_SELFTEST_SNAPSHOT_DIR"] {
                try? await Task.sleep(for: .milliseconds(600)) // let the sidebar render the new tab
                func save(_ rep: NSBitmapImageRep?, _ name: String) {
                    if let png = rep?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                    }
                }
                if let content = window.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    save(rep, "window")
                }
                if let image = try? await tab.webView.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation {
                    save(NSBitmapImageRep(data: tiff), "page")
                }
                if ProcessInfo.processInfo.environment["LILY_SELFTEST_COMMANDBAR"] != nil {
                    window.model.presentCommandBar(newTab: true)
                    window.model.commandBar?.query = "self"
                    try? await Task.sleep(for: .milliseconds(700))
                    if let content = window.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: rep)
                        save(rep, "commandbar")
                    }
                }
            }

            report["result"] = .string(failures.isEmpty ? "pass" : "fail")
            // The report is the self-test's output (stdout), not a log.
            FileHandle.standardOutput.write(Data((JSONValue.object(report).jsonString() + "\n").utf8))
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    /// Returns the scan and read counts as one string, or the error.
    private static func migrationProbe() async -> JSONValue {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lily-selftest-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Application Support/Dia/User Data/Default", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            var db: OpaquePointer?
            guard sqlite3_open(profile.appendingPathComponent("History").path, &db) == SQLITE_OK else { return ["ok": false, "error": "create"] }
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER); INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES ('https://selftest.example/', 'Self test', 2, 13300000000000000, 0), ('https://two.example/', 'Two', 1, 13300000000000000, 0);", nil, nil, nil)
            defer { sqlite3_close(db) } // left open: recent rows stay in the -wal file, like a running browser
            let granted: [MigrationRoot: URL] = [.applicationSupport: root.appendingPathComponent("Application Support", isDirectory: true)]
            guard let folder = MigrationEngine.locate(.dia, in: granted) else { return ["ok": false, "error": "not located"] }
            let scan = try await MigrationEngine.scan(.dia, folder: folder)
            let history = try await MigrationEngine.readHistory(.dia, folder: folder)
            // Also found when the Dia folder itself, or ~/Library, is what was granted.
            let viaOwnFolder = MigrationEngine.locate(.dia, in: [.applicationSupport: folder]) != nil
            let viaLibrary = MigrationEngine.locate(.dia, in: [.applicationSupport: root]) != nil
            return ["ok": .bool(scan.history == 2 && history.count == 2 && viaOwnFolder && viaLibrary), "scanned": JSONValue(scan.history), "read": JSONValue(history.count)]
        } catch {
            return ["ok": false, "error": .string(Sanitize.errorMessage(error))]
        }
    }

    /// Clicking an extension's action shows its popup in a popover sized to the popup's content
    /// (here 420×310), and dismissing the popover closes the popup. Its own page (`page`) opens in a
    /// tab, which needs a web view made from the extension's configuration, and the tab goes back to
    /// a regular web view for a web page. The self-test doesn't load the user's extensions, so this
    /// runs a fixture extension in a runtime of its own.
    @available(macOS 15.4, *)
    private static func extensionPopupProbe(window: BrowserWindowController, tab: Tab) async -> JSONValue {
        let manager = ExtensionManager(library: ExtensionLibrary(directory: nil))
        manager.windows = { [window] }
        manager.focusedWindow = { window }
        let controller = manager.controller
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lily-selftest-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(#"{"manifest_version": 3, "name": "Self Test Popup", "version": "1", "action": {"default_popup": "popup.html"}}"#.utf8)
                .write(to: root.appendingPathComponent("manifest.json"))
            try Data(#"<!doctype html><body style="margin:0"><div style="width:420px;height:310px">Popup</div></body>"#.utf8)
                .write(to: root.appendingPathComponent("popup.html"))
            try Data(#"<!doctype html><title>Extension Page</title><p>Welcome</p>"#.utf8).write(to: root.appendingPathComponent("page.html"))
            let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: root))
            try controller.load(context)
            defer { try? controller.unload(context) }
            window.registerWithExtensions(controller)
            context.performAction(for: tab)
            guard let action = context.action(for: tab) else { return ["ok": false, "error": "no action"] }
            let shown = await waitUntil(10) {
                guard let size = action.popupPopover?.contentSize, action.popupPopover?.isShown == true else { return false }
                return abs(size.width - 420) < 2 && abs(size.height - 310) < 2
            }
            let size = action.popupPopover?.contentSize ?? .zero
            action.popupPopover?.performClose(nil)
            let closed = await waitUntil(5) { action.popupPopover?.isShown != true }

            window.factory.extensionPageConfiguration = { controller.extensionContext(for: $0)?.webViewConfiguration }
            defer { window.factory.extensionPageConfiguration = nil }
            let pageTab = window.tabs.create(url: context.baseURL.appendingPathComponent("page.html"))
            defer { window.tabs.close(pageTab.id) }
            let rendered = await waitUntil(10) { pageTab.title == "Extension Page" }
            let extensionView = pageTab.webView
            pageTab.load(URL(string: "https://selftest.lily.test/after")!)
            // A regular web view again: Lily's page scripts are back.
            let switched = pageTab.webView !== extensionView && !pageTab.webView.configuration.userContentController.userScripts.isEmpty
            let page: JSONValue = ["ok": .bool(rendered && switched), "rendered": .bool(rendered), "backToWebView": .bool(switched)]
            return ["ok": .bool(shown && closed), "shown": .bool(shown), "closed": .bool(closed),
                    "size": .string("\(Int(size.width))×\(Int(size.height))"), "page": page]
        } catch {
            return ["ok": false, "error": .string(Sanitize.errorMessage(error))]
        }
    }

    private static func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
