import Foundation

/// Puts unused background tabs to sleep to free memory and save energy. Checks once a minute with a
/// wide timer tolerance (so macOS can batch the wake-up), and immediately on memory pressure.
@MainActor
final class TabSleeper {
    static let defaultMinutes = 15

    private weak var store: TabStore?
    private var loop: Task<Void, Never>?

    init(store: TabStore) {
        self.store = store
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(30))
                await self?.sweep(force: false)
            }
        }
    }

    func stop() { loop?.cancel() }

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
            if await tab.isBusy() { continue }
            tab.sleep()
        }
    }
}
