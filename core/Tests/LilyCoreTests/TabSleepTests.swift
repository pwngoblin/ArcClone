import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct TabSleepTests {
    let now = Date()

    func eligible(minutesIdle: Double, threshold: TimeInterval? = 900, active: Bool = false, split: Bool = false,
                  sleeping: Bool = false, scheme: String? = "https", force: Bool = false) -> Bool {
        TabSleeper.isEligible(lastActivated: now.addingTimeInterval(-minutesIdle * 60), now: now, threshold: threshold,
                              isActive: active, inSplit: split, isSleeping: sleeping, scheme: scheme, force: force)
    }

    @Test func onlyIdleBackgroundWebPagesSleep() {
        #expect(eligible(minutesIdle: 20))
        #expect(!eligible(minutesIdle: 5))
        #expect(!eligible(minutesIdle: 60, active: true))
        #expect(!eligible(minutesIdle: 60, split: true))
        #expect(!eligible(minutesIdle: 60, sleeping: true))
        #expect(!eligible(minutesIdle: 60, scheme: "file"))
        #expect(!eligible(minutesIdle: 60, threshold: nil)) // "Never"
    }

    @Test func memoryPressureIgnoresIdleTimeButNotVisibility() {
        #expect(eligible(minutesIdle: 0, force: true))
        #expect(eligible(minutesIdle: 0, threshold: nil, force: true))
        #expect(!eligible(minutesIdle: 0, active: true, force: true))
    }

    @Test func sleepingKeepsTheTabsIdentityAndActivationWakesIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registry = try ScriptRegistry(manifestURL: root.appendingPathComponent("injections/manifest.json"))
        let store = TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
        let first = store.create(url: URL(string: "https://sleep.invalid/page")!)
        let second = store.create(url: URL(string: "https://other.invalid/")!)
        #expect(store.activeID == second.id)
        first.sleep()
        #expect(first.isSleeping && first.url?.host == "sleep.invalid")
        store.activate(first.id)
        #expect(!first.isSleeping)
    }
}
