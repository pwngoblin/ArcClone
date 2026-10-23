import AppKit

/// `ArcClone --self-test`: boots the real app, loads a fixture page and exercises every IPC path
/// (chrome UI handshake, injection runtime, page events, native->page invoke, assistant),
/// prints a JSON report to stdout and exits non-zero on failure.
@MainActor
enum SelfTest {
    static let fixture = """
    <!doctype html><html lang="en"><head><title>ArcClone Self Test</title>
    <meta name="description" content="Fixture page for the self test">
    <link rel="icon" href="/icon.svg"></head>
    <body><nav><a href="/a">Home</a><a href="/b">About</a></nav>
    <article><h1>Self test heading</h1>
    <p>The quick brown fox jumps over the lazy dog. This paragraph exists so that the readable content extractor has enough text to score, with commas, clauses, and sentences.</p>
    <p>A second paragraph adds more weight to the article container, making it the obvious choice for extraction over the navigation links above.</p>
    <h2>Details</h2><ul><li>First item</li><li>Second item</li></ul></article>
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

            let tab = window.tabs.create(url: nil)
            tab.webView.loadHTMLString(fixture, baseURL: URL(string: "https://selftest.arcclone.test/article")!)
            let titled = await waitUntil(10) {
                tab.title == "ArcClone Self Test" && tab.faviconURL != nil && window.model.tabs.contains { $0.title == "ArcClone Self Test" }
            }
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

            // Page-world scripts must not be able to reach the native bridge.
            let leaked = try? await tab.webView.evaluateJavaScript("typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.arc)")
            check("page world isolated", (leaked as? String) == "undefined", JSONValue(leaked as? String))

            // Ollama itself is optional (CI has none); the assistant must answer health without failing.
            let health = await assistant.health()
            check("assistant", health["ollama"]?["reachable"]?.bool != nil, health)

            // The session must round-trip through the real Keychain key and never hit disk in plaintext.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = SessionStore(directory: dir)
            let sample = SessionStore.Session(tabs: [.init(url: URL(string: "https://selftest.arcclone.test/?token=s3cret")!, title: "T", pinned: false)],
                                              activeIndex: 0)
            await store.save(sample)
            let onDisk = (try? Data(contentsOf: dir.appendingPathComponent("session.sealed"))) ?? Data()
            let restored = await store.load()
            check("session encrypted at rest", restored == sample && !onDisk.isEmpty && onDisk.range(of: Data("s3cret".utf8)) == nil,
                  ["bytes": JSONValue(onDisk.count)])

            // Optional live HTTPS-First check (needs network): ARCCLONE_SELFTEST_NETWORK=1
            if ProcessInfo.processInfo.environment["ARCCLONE_SELFTEST_NETWORK"] != nil {
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

            // Optional live check against YouTube (needs network): ARCCLONE_SELFTEST_YOUTUBE=<videoId>
            if let videoID = ProcessInfo.processInfo.environment["ARCCLONE_SELFTEST_YOUTUBE"] {
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

            if let dir = ProcessInfo.processInfo.environment["ARCCLONE_SELFTEST_SNAPSHOT_DIR"] {
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
                if ProcessInfo.processInfo.environment["ARCCLONE_SELFTEST_COMMANDBAR"] != nil {
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
            print(JSONValue.object(report).jsonString())
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
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
