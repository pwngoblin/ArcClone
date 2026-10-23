import AppKit

/// IPC routes the Svelte chrome calls: tabs, navigation, window commands.
extension BrowserWindowController {
    func registerChromeHandlers() {
        let chromeOnly: Set<IPCSource.Kind> = [.chrome]

        router.on("chrome.ready", from: chromeOnly) { [weak self] _, _ in
            guard let self else { throw IPCError.unavailable("Window closed") }
            // Reply first, then flush queued events on the next pass so the UI has its listeners up.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.chrome.events.markReady() } }
            return [
                "state": self.stateSnapshot,
                "agent": self.agent.client.status.json,
                "selection": JSONValue(self.tabs.active?.lastSelection),
                "platform": "macos",
                "version": "0.1.0",
            ]
        }

        router.on("tabs.list", from: chromeOnly) { [weak self] _, _ in
            self?.stateSnapshot ?? .null
        }

        router.on("tabs.create", from: chromeOnly) { [weak self] _, p in
            guard let self else { return .null }
            let url = p["url"]?.string.flatMap { self.urlResolver.resolve($0) }
            let tab = self.tabs.create(url: url, activate: p["activate"]?.bool ?? true, pinned: p["pinned"]?.bool ?? false)
            return ["id": .string(tab.id.uuidString)]
        }

        router.on("tabs.close", from: chromeOnly) { [weak self] _, p in
            self?.tabs.close(try p.requiredUUID("id"))
            return .null
        }

        router.on("tabs.activate", from: chromeOnly) { [weak self] _, p in
            let id = try p.requiredUUID("id")
            guard let self, self.tabs.tab(id) != nil else { throw IPCError.notFound("No such tab") }
            self.tabs.activate(id)
            return .null
        }

        router.on("tabs.setPinned", from: chromeOnly) { [weak self] _, p in
            self?.tabs.setPinned(try p.requiredUUID("id"), p["pinned"]?.bool ?? true)
            return .null
        }

        router.on("tabs.move", from: chromeOnly) { [weak self] _, p in
            guard let index = p["index"]?.int else { throw IPCError.invalidParams("'index' must be a number") }
            self?.tabs.move(try p.requiredUUID("id"), to: index)
            return .null
        }

        router.on("tabs.reopenClosed", from: chromeOnly) { [weak self] _, _ in
            ["reopened": .bool(self?.tabs.reopenClosed() != nil)]
        }

        router.on("nav.go", from: chromeOnly) { [weak self] _, p in
            try self?.open(input: try p.requiredString("input"), newTab: p["newTab"]?.bool ?? false)
            return .null
        }

        router.on("nav.back", from: chromeOnly) { [weak self] _, _ in self?.tabs.active?.goBack(); return .null }
        router.on("nav.forward", from: chromeOnly) { [weak self] _, _ in self?.tabs.active?.goForward(); return .null }
        router.on("nav.reload", from: chromeOnly) { [weak self] _, _ in self?.tabs.active?.reload(); return .null }
        router.on("nav.stop", from: chromeOnly) { [weak self] _, _ in self?.tabs.active?.stop(); return .null }

        router.on("nav.suggest", from: chromeOnly) { [weak self] _, p in
            // Local suggestions: open tabs matching the query. Remote search suggestions are deliberately not used.
            let q = (p["query"]?.string ?? "").lowercased()
            guard let self, !q.isEmpty else { return .array([]) }
            let hits = self.tabs.tabs.filter {
                $0.title.lowercased().contains(q) || ($0.url?.absoluteString.lowercased().contains(q) ?? false)
            }
            return .array(hits.prefix(6).map { ["kind": "tab", "id": .string($0.id.uuidString), "title": .string($0.title), "url": JSONValue($0.url?.absoluteString)] })
        }

        router.on("window.toggleSidebar", from: chromeOnly) { [weak self] _, _ in
            self?.toggleSidebar(nil)
            return .null
        }

        router.on("page.focus", from: chromeOnly) { [weak self] _, _ in
            if let web = self?.tabs.active?.webView { self?.window?.makeFirstResponder(web) }
            return .null
        }

        router.on("youtube.seek", from: chromeOnly) { [weak self] _, p in
            guard let tab = self?.tabs.active else { throw IPCError.notFound("No active tab") }
            return try await tab.callInjection("youtube.seek", ["seconds": .number(p["seconds"]?.double ?? 0)])
        }

        router.on("page.scrollToHeading", from: chromeOnly) { [weak self] _, p in
            guard let tab = self?.tabs.active else { throw IPCError.notFound("No active tab") }
            return try await tab.callInjection("dom.scrollToHeading", p)
        }

        router.on("page.outline", from: chromeOnly) { [weak self] _, _ in
            guard let tab = self?.tabs.active else { throw IPCError.notFound("No active tab") }
            return try await tab.callInjection("dom.outline")
        }
    }
}
