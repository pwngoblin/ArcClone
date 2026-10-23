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

@Suite @MainActor struct SidebarSplitGroupingTests {
    func tab(_ title: String, pinned: Bool = false) -> WindowModel.TabItem {
        .init(id: UUID(), title: title, url: nil, favicon: nil, isLoading: false, isPinned: pinned, isYouTubeVideo: false, inSplit: false)
    }

    @Test func splitMembersFoldIntoOneItemAtTheFirstMember() {
        let model = WindowModel(isPrivate: false, assistant: AssistantChat(assistant: Assistant(configuration: .init())))
        let a = tab("A"), b = tab("B"), c = tab("C"), d = tab("D"), pinned = tab("P", pinned: true)
        model.tabs = [pinned, a, b, c, d]
        model.splitLayout = .twoColumns
        model.splitIDs = [d.id, b.id]
        let items = model.regularItems
        #expect(items.count == 3)
        guard case .tab(let first) = items[0], case .split(let layout, let members) = items[1], case .tab(let last) = items[2] else {
            Issue.record("unexpected items \(items.map(\.id))"); return
        }
        #expect(first.id == a.id && last.id == c.id && layout == .twoColumns)
        #expect(members.map(\.id) == [d.id, b.id]) // pane order, not sidebar order
    }

    @Test func noSplitMeansOneItemPerTab() {
        let model = WindowModel(isPrivate: false, assistant: AssistantChat(assistant: Assistant(configuration: .init())))
        model.tabs = [tab("A"), tab("B")]
        #expect(model.regularItems.count == 2)
    }
}
