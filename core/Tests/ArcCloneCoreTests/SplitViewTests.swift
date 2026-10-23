import Foundation
import Testing
@testable import ArcCloneCore

@Suite struct SplitViewTests {
    let ids = (0..<5).map { _ in UUID() }

    @Test func paneCountsMatchLayouts() {
        #expect(SplitLayout.allCases.map(\.paneCount) == [2, 2, 3, 3, 4])
    }

    @Test func closingAPaneShrinksTheLayout() {
        let grid = SplitGroup(layout: .grid, tabIDs: Array(ids.prefix(4)))
        let three = grid.removing(ids[1])
        #expect(three?.layout == .threeColumns && three?.tabIDs == [ids[0], ids[2], ids[3]])
        let two = three?.removing(ids[0])
        #expect(two?.layout == .twoColumns && two?.tabIDs == [ids[2], ids[3]])
        #expect(two?.removing(ids[2]) == nil)
        let rows = SplitGroup(layout: .threeRows, tabIDs: Array(ids.prefix(3))).removing(ids[2])
        #expect(rows?.layout == .twoRows)
    }

    @Test func removingAnUnrelatedTabChangesNothing() {
        let group = SplitGroup(layout: .twoColumns, tabIDs: Array(ids.prefix(2)))
        #expect(group.removing(ids[4]) == group)
    }

    @Test func addingGrowsUpToFourAndRejectsDuplicates() {
        var group = SplitGroup(layout: .twoRows, tabIDs: Array(ids.prefix(2)))
        group = group.adding(ids[2])!
        #expect(group.layout == .threeRows)
        group = group.adding(ids[3])!
        #expect(group.layout == .grid && group.tabIDs.count == 4)
        #expect(group.adding(ids[4]) == nil)
        #expect(SplitGroup(layout: .twoColumns, tabIDs: Array(ids.prefix(2))).adding(ids[0]) == nil)
    }
}
