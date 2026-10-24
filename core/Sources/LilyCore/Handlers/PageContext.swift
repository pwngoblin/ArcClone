import Foundation

extension BrowserWindowController {
    /// Collects page text, transcript and selection from the active tab for the assistant.
    /// Failures degrade to less context rather than failing the request.
    func gatherContext(includePage: Bool, includeSelection: Bool) async -> (page: PageContent?, transcript: Transcript?, selection: String?) {
        guard let tab = tabs.active else { return (nil, nil, nil) }
        var page: PageContent?
        var transcript: Transcript?
        if includePage, tab.url?.scheme == "http" || tab.url?.scheme == "https" {
            if tab.youtubeVideoID != nil {
                transcript = try? await tab.callInjection("youtube.transcript", [:], timeout: 30).decode(Transcript.self)
            }
            do {
                page = try await tab.callInjection("dom.extract", ["maxChars": 120000]).decode(PageContent.self)
            } catch {
                Log.agent.info("Page extraction failed: \(String(describing: error), privacy: .public)")
                page = PageContent(url: tab.url?.absoluteString, title: tab.title, text: "")
            }
        }
        return (page, transcript, includeSelection ? tab.lastSelection : nil)
    }
}
