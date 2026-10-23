import Foundation

/// IPC routes that injected content scripts call (`window.__arc.emit/send`).
/// Page sources are only allowed these routes; everything else is rejected by the router.
extension BrowserWindowController {
    func registerPageHandlers() {
        let pageOnly: Set<IPCSource.Kind> = [.page]

        router.on("page.didChange", from: pageOnly) { [weak self] ctx, p in
            guard let self, case .page(let tabID, true, _) = ctx.source, let tab = self.tabs.tab(tabID) else { return .null }
            tab.applyMetadata(p)
            self.assistant.context.ingest(tabID: tabID, type: "page.didChange", payload: p)
            return .null
        }

        router.on("selection.changed", from: pageOnly) { [weak self] ctx, p in
            guard let self, let tabID = ctx.source.tabID, let tab = self.tabs.tab(tabID) else { return .null }
            let text = p["text"]?.string
            tab.applySelection(text)
            self.assistant.context.ingest(tabID: tabID, type: "selection.changed", payload: p)
            if tabID == self.tabs.activeID {
                self.chrome.events.send("page.selection", ["tabId": .string(tabID.uuidString), "text": JSONValue(text)])
            }
            return .null
        }

        router.on("selection.cleared", from: pageOnly) { [weak self] ctx, _ in
            guard let self, let tabID = ctx.source.tabID, let tab = self.tabs.tab(tabID) else { return .null }
            tab.applySelection(nil)
            self.assistant.context.ingest(tabID: tabID, type: "selection.cleared", payload: .null)
            if tabID == self.tabs.activeID {
                self.chrome.events.send("page.selection", ["tabId": .string(tabID.uuidString), "text": .null])
            }
            return .null
        }

        router.on("youtube.videoChanged", from: pageOnly) { [weak self] ctx, p in
            guard let self, case .page(let tabID, true, _) = ctx.source, let tab = self.tabs.tab(tabID) else { return .null }
            tab.applyYouTubeVideo(p["videoId"]?.string)
            self.assistant.context.ingest(tabID: tabID, type: "youtube.videoChanged", payload: p)
            return .null
        }

        router.on("runtime.error", from: pageOnly) { ctx, p in
            Log.scripts.error("Injection error \(p["source"]?.string ?? "?", privacy: .public):\(p["line"]?.int ?? 0): \(p["message"]?.string ?? "", privacy: .public) [\(ctx.source.tabID?.uuidString ?? "-", privacy: .public)]")
            return .null
        }

        // Any other page event is still useful assistant context.
        router.onUnhandledEvent = { [weak self] ctx, type, payload in
            guard let self, let tabID = ctx.source.tabID else { return }
            self.assistant.context.ingest(tabID: tabID, type: type, payload: payload)
        }
    }
}
