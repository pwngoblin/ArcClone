import Foundation

/// IPC routes that injected content scripts call (`window.__arc.emit/send`).
/// Page sources are only allowed these routes; payloads are schema-validated (`PagePayload`) and
/// unknown event types are dropped.
extension BrowserWindowController {
    func registerPageHandlers() {
        let pageOnly: Set<IPCSource.Kind> = [.page]

        router.on("page.didChange", from: pageOnly, as: PagePayload.DidChange.self) { [weak self] ctx, p in
            guard let self, case .page(let tabID, true, let origin) = ctx.source, let tab = self.tabs.tab(tabID) else { return .null }
            let metadata = try PagePayload.metadata(p, origin: origin)
            tab.applyMetadata(metadata)
            self.recordForAssistant(tabID, "page.didChange", metadata.json)
            return .null
        }

        router.on("selection.changed", from: pageOnly, as: PagePayload.Selection.self) { [weak self] ctx, p in
            guard let self, case .page(let tabID, _, let origin) = ctx.source, let tab = self.tabs.tab(tabID) else { return .null }
            let selection = try PagePayload.selection(p, origin: origin)
            tab.applySelection(selection.text)
            self.recordForAssistant(tabID, "selection.changed", ["text": .string(selection.text), "url": .string(selection.url.absoluteString)])
            if tabID == self.tabs.activeID { self.model.selection = selection.text }
            return .null
        }

        router.on("selection.cleared", from: pageOnly) { [weak self] ctx, _ in
            guard let self, let tabID = ctx.source.tabID, let tab = self.tabs.tab(tabID) else { return .null }
            tab.applySelection(nil)
            self.recordForAssistant(tabID, "selection.cleared", .null)
            if tabID == self.tabs.activeID { self.model.selection = nil }
            return .null
        }

        router.on("youtube.videoChanged", from: pageOnly, as: PagePayload.VideoChanged.self) { [weak self] ctx, p in
            guard let self, case .page(let tabID, true, let origin) = ctx.source, let tab = self.tabs.tab(tabID) else { return .null }
            let videoID = try PagePayload.videoID(p, origin: origin)
            tab.applyYouTubeVideo(videoID)
            self.recordForAssistant(tabID, "youtube.videoChanged", ["videoId": JSONValue(videoID)])
            return .null
        }

        router.on("runtime.error", from: pageOnly, as: PagePayload.RuntimeError.self) { ctx, p in
            // Only errors raised inside our own injection files are reported.
            guard let source = p.source, source.hasPrefix("arc-injection://"), source.count < 200 else { return .null }
            Log.scripts.error("Injection error \(source, privacy: .public):\(p.line ?? 0): \(PagePayload.bounded(p.message, PagePayload.maxMessage) ?? "", privacy: .private) [\(ctx.source.tabID?.uuidString ?? "-", privacy: .public)]")
            return .null
        }

        // Unknown page events are ignored rather than forwarded anywhere.
        router.onUnhandledEvent = { _, type, _ in
            Log.scripts.debug("Dropped unknown page event \(type.prefix(64), privacy: .public)")
        }
    }

    /// Private windows leave no trace in the assistant's context.
    private func recordForAssistant(_ tabID: UUID, _ type: String, _ payload: JSONValue) {
        guard !isPrivate else { return }
        assistant.context.ingest(tabID: tabID, type: type, payload: payload)
    }
}
