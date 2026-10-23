import Foundation
import Testing
import WebKit
@testable import ArcCloneCore

@Suite struct FilterListConverterTests {
    func trigger(_ rule: [String: Any]) -> [String: Any] { rule["trigger"] as? [String: Any] ?? [:] }
    func action(_ rule: [String: Any]) -> String? { (rule["action"] as? [String: Any])?["type"] as? String }

    @Test func addressAnchoredRulesBecomeDomainRegexes() throws {
        let rule = try #require(FilterListConverter.networkRule("||ads.example.com^", exception: false))
        #expect(trigger(rule)["url-filter"] as? String == "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[/:?=&]")
        #expect(action(rule) == "block")
    }

    @Test func optionsMapToTriggerFields() throws {
        let rule = try #require(FilterListConverter.networkRule("||track.example^$third-party,script,domain=a.com|b.com", exception: false))
        #expect(trigger(rule)["load-type"] as? [String] == ["third-party"])
        #expect(trigger(rule)["resource-type"] as? [String] == ["script"])
        #expect(trigger(rule)["if-domain"] as? [String] == ["*a.com", "*b.com"])
        let unless = try #require(FilterListConverter.networkRule("||x.example^$domain=~safe.com", exception: false))
        #expect(trigger(unless)["unless-domain"] as? [String] == ["*safe.com"])
    }

    @Test func unsupportedFiltersAreSkippedNotApproximated() {
        #expect(FilterListConverter.networkRule("||x.example^$redirect=noop.js", exception: false) == nil)
        #expect(FilterListConverter.networkRule("/banner/*/ad.", exception: false) == nil)
        #expect(FilterListConverter.networkRule("||x.example/a|b", exception: false) == nil)
    }

    @Test func fullListKeepsExceptionsLastAndBatchesCosmetics() {
        let list = """
        [Adblock Plus 2.0]
        ! comment
        ||ads.example^
        @@||ads.example^$domain=good.com
        ##.ad-banner
        ##.sponsored
        news.example##.promo
        example.com#@#.ad
        ##+js(nowebrtc)
        site.example#?#div:-abp-has(.ad)
        """
        let rules = FilterListConverter.convert(list)
        #expect(rules.count == 4)
        #expect(action(rules.first!) == "block")
        #expect(action(rules.last!) == "ignore-previous-rules")
        let cosmetic = rules.compactMap { $0["action"] as? [String: Any] }.compactMap { $0["selector"] as? String }
        #expect(cosmetic.contains(".ad-banner, .sponsored") && cosmetic.contains(".promo"))
    }
}

@Suite @MainActor struct ContentRuleCompilationTests {
    func compile(_ rules: [[String: Any]]) async throws -> WKContentRuleList? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try #require(WKContentRuleListStore(url: dir))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        return try await store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: json)
    }

    /// WebKit rejects regexes outside its subset (e.g. "|"); the built-in list must compile.
    @Test func builtinListCompiles() async throws {
        #expect(try await compile(BuiltinBlocklist.rules) != nil)
    }

    @Test func convertedRulesCompile() async throws {
        let rules = FilterListConverter.convert("""
        ||doubleclick.net^$third-party
        ||cdn.example/ads/*.js$script
        @@||cdn.example/ads/allowed.js
        ##.adsbygoogle
        news.example##.promo-box
        """)
        #expect(try await compile(rules) != nil)
    }
}

/// Opt-in (network): ARCCLONE_TEST_EASYLIST=1 swift test --filter RealFilterListTests
@Suite @MainActor struct RealFilterListTests {
    @Test func realEasyListConvertsAndCompiles() async throws {
        guard ProcessInfo.processInfo.environment["ARCCLONE_TEST_EASYLIST"] != nil else { return }
        var text = ""
        for source in AdBlocker.sources { text += String(decoding: try await URLSession.shared.data(from: source).0, as: UTF8.self) + "\n" }
        let rules = FilterListConverter.convert(text)
        print("EasyList + EasyPrivacy: \(text.split(whereSeparator: \.isNewline).count) lines -> \(rules.count) rules")
        #expect(rules.count > 10_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-easylist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try #require(WKContentRuleListStore(url: dir))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        let started = Date()
        #expect(try await store.compileContentRuleList(forIdentifier: "easylist", encodedContentRuleList: json) != nil)
        print("Compiled in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }
}
