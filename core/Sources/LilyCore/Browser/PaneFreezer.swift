import AppKit

/// Pausing split panes you aren't using. WebKit can't throttle a page that's on screen, but it
/// suspends a hidden one's timers, animation frames and rendering (`inactiveSchedulingPolicy =
/// .suspend`). So a pane that hasn't been focused for a while gets a still picture of itself and
/// its web view is hidden; clicking or scrolling it brings the page back, exactly where it was.
///
/// Never paused: the pane you're in, panes playing media or using the camera or microphone,
/// loading pages, and panes of a split with Link Scrolling (they have to keep following).
enum PaneFreezer {
    static let defaultMinutes = 5

    /// How long a pane stays unfocused before it pauses (at most a minute in Low Power Mode); nil when off.
    static var threshold: TimeInterval? {
        let stored = UserDefaults.standard.object(forKey: Preferences.Key.pauseIdlePanesAfter) as? Int ?? defaultMinutes
        guard stored > 0 else { return nil }
        return TimeInterval((ProcessInfo.processInfo.isLowPowerModeEnabled ? min(stored, 1) : stored) * 60)
    }

    /// When the next pane could pause: the earliest unfocused pane's idle deadline, or a full
    /// threshold from now when that's already past (a pane that was busy is looked at again later,
    /// not every second).
    static func nextCheck(idleSince: [Date], threshold: TimeInterval, now: Date = Date()) -> TimeInterval? {
        guard let due = idleSince.map({ $0.addingTimeInterval(threshold) }).min() else { return nil }
        return due > now ? due.timeIntervalSince(now) : threshold
    }
}

extension BrowserWindowController {
    /// After the active tab or split changes: one wake-up for the next pane that could pause.
    func scheduleFreeze() {
        freezeTask?.cancel()
        freezeTask = nil
        guard let threshold = PaneFreezer.threshold, let split = tabs.split, !split.scrollLinked else {
            if tabs.split?.scrollLinked == true { contentController.thawAll() }
            return
        }
        let idle = split.tabIDs.filter { $0 != tabs.activeID && !contentController.isFrozen($0) }.compactMap(tabs.tab)
        guard let delay = PaneFreezer.nextCheck(idleSince: idle.map(\.lastActivated), threshold: threshold) else { return }
        freezeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(max(5, delay * 0.1)))
            guard !Task.isCancelled, let self else { return }
            await self.freezeIdlePanes(threshold: threshold)
            self.scheduleFreeze()
        }
    }

    func freezeIdlePanes(threshold: TimeInterval, now: Date = Date()) async {
        guard let split = tabs.split, !split.scrollLinked else { return }
        for id in split.tabIDs where id != tabs.activeID && !contentController.isFrozen(id) {
            guard let tab = tabs.tab(id), tab.hasWebView, !tab.isLoading, now.timeIntervalSince(tab.lastActivated) >= threshold,
                  await !tab.isBusy(), let picture = try? await tab.webView.takeSnapshot(configuration: nil) else { continue }
            // Still an unfocused pane of a split that may pause, after the awaits?
            guard tabs.split?.tabIDs.contains(id) == true, tabs.split?.scrollLinked == false, id != tabs.activeID else { continue }
            contentController.freeze(id, snapshot: picture)
        }
    }
}
