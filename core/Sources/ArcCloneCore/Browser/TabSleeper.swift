import Foundation

/// Puts unused background tabs to sleep to free memory and save energy. It doesn't poll: it waits
/// until the earliest moment a background tab could have been idle long enough (with a wide timer
/// tolerance, so macOS can batch the wake-up), and doesn't wake at all while no tab could sleep.
/// Memory pressure sleeps eligible tabs at once.
@MainActor
final class TabSleeper {
    static let defaultMinutes = 15
    /// A tab that's busy (playing media, using the camera) is looked at again after this long.
    static let busyRecheck: TimeInterval = 5 * 60

    private weak var store: TabStore?
    private var timer: Task<Void, Never>?
    private var busyUntil: [UUID: Date] = [:]
    /// When the pending wake-up is due (nil when none is scheduled).
    private(set) var nextCheck: Date?

    init(store: TabStore) {
        self.store = store
        reschedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        nextCheck = nil
    }

    /// Called when tabs are switched, opened or closed: waits until the next tab could sleep.
    func reschedule(now: Date = Date()) {
        guard let store, let threshold = Self.threshold else { stop(); return }
        let due = store.tabs.compactMap { tab -> Date? in
            guard Self.isEligible(lastActivated: .distantPast, now: now, threshold: threshold, isActive: tab.id == store.activeID,
                                  inSplit: store.split?.tabIDs.contains(tab.id) ?? false,
                                  isSleeping: tab.isSleeping, scheme: tab.url?.scheme, force: false) else { return nil }
            return max(tab.lastActivated.addingTimeInterval(threshold), busyUntil[tab.id] ?? .distantPast)
        }.min()
        guard let due else { stop(); return }
        if let nextCheck, abs(nextCheck.timeIntervalSince(due)) < 1, timer != nil { return } // already set
        timer?.cancel()
        nextCheck = due
        let delay = max(1, due.timeIntervalSince(now))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(max(30, delay * 0.1)))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.nextCheck = nil
            await self.sweep(force: false)
            self.reschedule()
        }
    }

    /// Minutes of inactivity before a tab sleeps (shorter in Low Power Mode); nil when disabled.
    static var threshold: TimeInterval? {
        let stored = UserDefaults.standard.object(forKey: Preferences.Key.sleepTabsAfter) as? Int ?? defaultMinutes
        guard stored > 0 else { return nil }
        let minutes = ProcessInfo.processInfo.isLowPowerModeEnabled ? min(stored, 5) : stored
        return TimeInterval(minutes * 60)
    }

    /// Whether a tab may sleep: not visible, not already asleep, a web page, idle long enough.
    nonisolated static func isEligible(lastActivated: Date, now: Date, threshold: TimeInterval?, isActive: Bool, inSplit: Bool,
                                       isSleeping: Bool, scheme: String?, force: Bool) -> Bool {
        guard !isActive, !inSplit, !isSleeping, scheme == "https" || scheme == "http" else { return false }
        if force { return true }
        guard let threshold else { return false }
        return now.timeIntervalSince(lastActivated) >= threshold
    }

    /// `force`: memory pressure — sleep every eligible tab regardless of idle time.
    func sweep(force: Bool) async {
        guard let store else { return }
        let now = Date()
        let threshold = Self.threshold
        for tab in store.tabs where Self.isEligible(lastActivated: tab.lastActivated, now: now, threshold: threshold,
                                                    isActive: tab.id == store.activeID,
                                                    inSplit: store.split?.tabIDs.contains(tab.id) ?? false,
                                                    isSleeping: tab.isSleeping, scheme: tab.url?.scheme, force: force) {
            if await tab.isBusy() {
                busyUntil[tab.id] = now.addingTimeInterval(Self.busyRecheck)
                continue
            }
            busyUntil[tab.id] = nil
            tab.sleep()
        }
    }
}
