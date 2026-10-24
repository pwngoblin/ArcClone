import Foundation
import Testing
@testable import ArcCloneCore

@Suite struct PaneFreezerTests {
    private let now = Date()

    @Test func waitsForTheEarliestIdlePane() {
        let idle = [now.addingTimeInterval(-60), now.addingTimeInterval(-240)]
        #expect(PaneFreezer.nextCheck(idleSince: idle, threshold: 300, now: now) == 60)
    }

    @Test func aPaneThatCouldntPauseIsCheckedAgainLaterNotInALoop() {
        // Already past its deadline (it was busy playing media): a full threshold, not 0 or 1 s.
        #expect(PaneFreezer.nextCheck(idleSince: [now.addingTimeInterval(-900)], threshold: 300, now: now) == 300)
    }

    @Test func nothingToScheduleWithoutIdlePanes() {
        #expect(PaneFreezer.nextCheck(idleSince: [], threshold: 300, now: now) == nil)
    }
}
