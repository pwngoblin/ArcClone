import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct ScrollLinkTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func linkingSurvivesGrowingShrinkingAndRelayout() throws {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        let tabs = TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
        let a = tabs.create(url: nil)
        let b = tabs.create(url: nil, activate: false)
        let c = tabs.create(url: nil, activate: false)
        tabs.activate(a.id)
        tabs.makeSplit(.twoColumns, with: [b.id])
        #expect(tabs.split?.scrollLinked == false)

        tabs.setScrollLinked(true)
        tabs.addToSplit(c.id)
        #expect(tabs.split?.layout == .threeColumns && tabs.split?.scrollLinked == true)
        tabs.makeSplit(.threeRows)
        #expect(tabs.split?.scrollLinked == true)
        tabs.removeFromSplit(c.id)
        tabs.activate(a.id) // adding c made it active; the split on screen is a's again
        #expect(tabs.split?.layout.paneCount == 2 && tabs.split?.scrollLinked == true)
        tabs.setScrollLinked(false)
        #expect(tabs.split?.scrollLinked == false)
    }

    @Test func positionsFromPagesAreClamped() throws {
        func decode(_ json: String) throws -> JSONValue {
            try JSONDecoder().decode(PagePayload.ScrollPosition.self, from: Data(json.utf8)).clamped
        }
        #expect(try decode(#"{"x": 0.25, "y": 0.5}"#) == ["x": 0.25, "y": 0.5])
        #expect(try decode(#"{"x": -3, "y": 1e9}"#) == ["x": 0, "y": 1])
        #expect(throws: (any Error).self) { try decode(#"{"y": "top"}"#) }
    }
}
