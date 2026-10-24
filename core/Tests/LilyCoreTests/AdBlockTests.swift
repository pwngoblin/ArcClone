import Foundation
import Testing
import WebKit
@testable import LilyCore

private func trigger(_ rule: [String: Any]) -> [String: Any] { rule["trigger"] as? [String: Any] ?? [:] }
private func action(_ rule: [String: Any]) -> String? { (rule["action"] as? [String: Any])?["type"] as? String }
private func selectors(_ rules: [[String: Any]]) -> [String] {
    rules.compactMap { ($0["action"] as? [String: Any])?["selector"] as? String }
}

@Suite struct NetworkFilterTests {
    func only(_ filter: String, exception: Bool = false) throws -> [String: Any] {
        let rules = FilterListConverter.networkRules(filter, exception: exception)
        try #require(rules.count == 1, "\(filter) → \(rules)")
        return rules[0]
    }

    @Test func addressAnchoredRulesBecomeDomainRegexes() throws {
        let rule = try only("||ads.example.com^")
        #expect(trigger(rule)["url-filter"] as? String == "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[/:?=&]")
        #expect(action(rule) == "block")
    }

    @Test func anchorsPlainPatternsAndRegexes() throws {
        #expect(trigger(try only("|https://cdn.example/ad.js|"))["url-filter"] as? String == "^https://cdn\\.example/ad\\.js$")
        #expect(trigger(try only("/banner/*/ad."))["url-filter"] as? String == "/banner/.*/ad\\.")
        #expect(trigger(try only("*-ad-unit-"))["url-filter"] as? String == "-ad-unit-")
        #expect(trigger(try only(#"/^https?:\/\/[a-z]+\.example\/\d+\.js/$script"#))["url-filter"] as? String
                == #"^https?://[a-z]+\.example/[0-9]+\.js"#)
    }

    @Test func optionsMapToTriggerFields() throws {
        let rule = try only("||track.example^$third-party,script,domain=a.com|b.com")
        #expect(trigger(rule)["load-type"] as? [String] == ["third-party"])
        #expect(trigger(rule)["resource-type"] as? [String] == ["script"])
        #expect(trigger(rule)["if-domain"] as? [String] == ["*a.com", "*b.com"])
        #expect(trigger(try only("||x.example^$domain=~safe.com"))["unless-domain"] as? [String] == ["*safe.com"])
        #expect(trigger(try only("||x.example^$1p,xhr,css"))["resource-type"] as? [String] == ["fetch", "style-sheet"])
        #expect(trigger(try only("||x.example^$3p"))["load-type"] as? [String] == ["third-party"])
        #expect(trigger(try only("||x.example^$popup"))["resource-type"] as? [String] == ["popup"])
    }

    @Test func framesAreChildFrameDocuments() throws {
        let frame = try only("||ads.example^$subdocument")
        #expect(trigger(frame)["resource-type"] as? [String] == ["document"])
        #expect(trigger(frame)["load-context"] as? [String] == ["child-frame"])
        // Mixed with other types: a separate rule, so scripts aren't limited to frames.
        #expect(FilterListConverter.networkRules("||ads.example^$script,frame", exception: false).count == 2)
    }

    @Test func negatedTypesMeanEverythingElse() throws {
        let rules = FilterListConverter.networkRules("||cdn.example^$~script", exception: false)
        let types = rules.compactMap { trigger($0)["resource-type"] as? [String] }
        #expect(types.contains { !$0.contains("script") && $0.contains("image") })
        #expect(types.contains(["document"])) // frames still included
    }

    @Test func typelessExceptionsLeaveThePageItselfAlone() {
        let rules = FilterListConverter.networkRules("||cdn.example^", exception: true)
        #expect(rules.allSatisfy { action($0) == "ignore-previous-rules" })
        let types = rules.compactMap { trigger($0)["resource-type"] as? [String] }
        #expect(types.count == 2 && !types[0].contains("document") && types[1] == ["document"])
    }

    @Test func domainExclusionsThatNarrowAnIncludeAreSkipped() {
        #expect(FilterListConverter.networkRules("||x.example^$domain=a.com|~shop.a.com", exception: false).isEmpty)
        #expect(FilterListConverter.networkRules("||x.example^$domain=a.com|~b.com", exception: false).count == 1)
        #expect(FilterListConverter.networkRules("||x.example^$domain=google.*", exception: false).isEmpty)
    }

    @Test func unsupportedFiltersAreSkippedNotApproximated() {
        for filter in ["||x.example^$redirect=noop.js", "||x.example^$csp=script-src 'none'", "||x.example^$removeparam=utm",
                       "||x.example/a|b", "/(ads|banners)/", #"/ad\b/"#, "/ad{2}/", "ad", "$script", "||x.example^$object"] {
            #expect(FilterListConverter.networkRules(filter, exception: false).isEmpty, "\(filter)")
        }
    }

    @Test func hostsFileLines() {
        #expect(FilterListConverter.hostsEntry("0.0.0.0 ads.example.com") == "ads.example.com")
        #expect(FilterListConverter.hostsEntry("127.0.0.1\ttracker.example # comment") == "tracker.example")
        #expect(FilterListConverter.hostsEntry("127.0.0.1 localhost") == nil)
        #expect(FilterListConverter.hostsEntry("0.0.0.0 0.0.0.0") == nil)
    }
}

@Suite struct CosmeticSelectorTests {
    @Test func plainCSSIsKept() {
        #expect(CosmeticSelector.parse(".ad-banner") == .css(".ad-banner"))
        #expect(CosmeticSelector.parse("div > a[href*=\"ads:\"]:not(.keep)") == .css("div > a[href*=\"ads:\"]:not(.keep)"))
        #expect(CosmeticSelector.parse("div:-abp-has(.ad)") == .css("div:has(.ad)"))
        // Tailwind-style escapes and semicolons inside quoted attribute values are harmless.
        #expect(CosmeticSelector.parse(#".h-\[90px\]"#) == .css(#".h-\[90px\]"#))
        #expect(CosmeticSelector.parse(#"div[style^="width:auto;"]"#) == .css(#"div[style^="width:auto;"]"#))
        #expect(CosmeticSelector.parse(#"a[aria-label="Реклама"]"#) != nil)
    }

    @Test func styleRulesAreLimitedToLayoutProperties() {
        #expect(CosmeticSelector.parse("body:style(overflow: auto !important; position: static)")
                == .procedural(ProceduralFilter(selector: "body", steps: [], style: "overflow: auto; position: static")))
        #expect(CosmeticSelector.parse("div.wall:has-text(cookies):style(display: none)") != nil)
        for bad in ["body:style(background: url(https://t.example/p.gif))", "body:style(background-image: none)",
                    "body:style(content: 'x')", "body:style(width: var(--x))", "body:style(overflow: auto):upward(1)",
                    "body:style(color: red)", "body:style()"] {
            #expect(CosmeticSelector.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func proceduralOperatorsBecomeSteps() {
        let parsed = CosmeticSelector.parse("div.post:has-text(/Sponsored|Promoted/i):upward(2)")
        #expect(parsed == .procedural(ProceduralFilter(selector: "div.post", steps: [
            .init(type: "has-text", arg: "/Sponsored|Promoted/i"), .init(type: "upward", arg: "2"),
        ])))
        #expect(CosmeticSelector.parse("span:-abp-contains(Ad (paid)):upward(article)")
                == .procedural(ProceduralFilter(selector: "span", steps: [.init(type: "has-text", arg: "Ad (paid)"), .init(type: "upward", arg: "article")])))
        #expect(CosmeticSelector.parse(".x:remove()") == .css(".x"))
    }

    @Test func unsupportedOrUnsafeSelectorsAreRefused() {
        for bad in [".ad{background:url(https://t.example/x)}", ".a;}body{display:none", "@import url(x)", ".x\\", ".a;.b",
                    "+js(nowebrtc)", "^script:has-text(ad)", ".x:style(color: red)", "div:matches-css(position: fixed)",
                    "div:xpath(//a)", "a::before", ".x:upward(99)", ".x:has-text(a):matches-path(/x)", "div:has(> span:has-text(ad))",
                    "div:has-text()", ".unbalanced(", "[data-x"] {
            #expect(CosmeticSelector.parse(bad) == nil, "\(bad)")
        }
    }
}

@Suite struct FilterListTests {
    @Test func fullListKeepsExceptionsLastAndBatchesCosmetics() {
        let rules = FilterListConverter.convert("""
        [Adblock Plus 2.0]
        ! comment
        ||ads.example^
        @@||ads.example^$domain=good.com
        ##.ad-banner
        ##.sponsored
        news.example##.promo
        ##+js(nowebrtc)
        site.example#$#body { color: red }
        """)
        #expect(action(rules.first!) == "block")
        #expect(action(rules.last!) == "ignore-previous-rules")
        #expect(selectors(rules).contains(".ad-banner, .sponsored") && selectors(rules).contains(".promo"))
    }

    @Test func cosmeticExceptionsRemoveOrScopeSelectors() {
        let rules = FilterListConverter.convert("""
        ##.ad
        ##.banner
        example.com#@#.ad
        news.example##.promo
        news.example#@#.promo
        #@#.banner
        """)
        let ad = rules.first { selectors([$0]).first == ".ad" }
        #expect(trigger(ad ?? [:])["unless-domain"] as? [String] == ["*example.com"])
        #expect(!selectors(rules).contains { $0.contains(".promo") || $0.contains(".banner") })
    }

    @Test func siteWideExceptions() {
        let parsed = FilterListConverter.parse("""
        ||ads.example^
        ##.ad
        shop.example##.promo
        @@||bank.example^$document
        @@||shop.example^$elemhide
        @@||blog.example^$generichide
        """)
        let rules = FilterListConverter.split(parsed, chunkSize: 1_000)[0]
        #expect(rules.contains { action($0) == "ignore-previous-rules" && trigger($0)["if-domain"] as? [String] == ["*bank.example"] })
        let generic = rules.first { selectors([$0]).first == ".ad" }
        #expect(Set(trigger(generic ?? [:])["unless-domain"] as? [String] ?? []) == ["*bank.example", "*shop.example", "*blog.example"])
        #expect(!selectors(rules).contains(".promo"))
    }

    @Test func badfilterCancelsItsTwin() {
        let rules = FilterListConverter.convert("""
        ||ads.example^$script,third-party
        ||ads.example^$third-party,script,badfilter
        ||other.example^
        """)
        #expect(rules.count == 1)
    }

    @Test func importantBlocksComeAfterExceptions() {
        let rules = FilterListConverter.convert("""
        ||tracker.example^$important
        @@||tracker.example^
        ||ads.example^
        """)
        #expect(action(rules.first!) == "block")
        #expect(action(rules.last!) == "block")
        #expect(rules.dropFirst().dropLast().allSatisfy { action($0) == "ignore-previous-rules" })
    }

    @Test func chunksEachCarryTheExceptions() {
        let blocks = (0..<250).map { "||ads\($0).example^" }.joined(separator: "\n")
        let chunks = FilterListConverter.split(FilterListConverter.parse(blocks + "\n@@||ads1.example^$domain=ok.com"), chunkSize: 100)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { action($0.last!) == "ignore-previous-rules" && $0.count <= 100 })
    }

    @Test func proceduralFiltersAreKeyedByDomainAndExceptionsApply() throws {
        let compiled = try FilterListConverter.compile("""
        social.example##article:has-text(Sponsored)
        social.example,video.example##div.card:has-text(Promoted):upward(1)
        video.example#@#div.card:has-text(Promoted):upward(1)
        ##div:has-text(Ad)
        """)
        #expect(compiled.procedural["social.example"]?.count == 2)
        #expect(compiled.procedural["video.example"] == nil)
        #expect(compiled.procedural.count == 1) // generic procedural filters aren't run on every page
    }

    @Test func entitiesAndNarrowedDomainsAreSkipped() {
        let rules = FilterListConverter.convert("""
        google.*##.ad
        example.com,~shop.example.com##.promo
        ~example.com##.banner
        ~google.*##.wide
        softonic.com,softonic.*##.sponsored
        """)
        #expect(Set(selectors(rules)) == [".banner", ".sponsored"])
        #expect(rules.contains { trigger($0)["if-domain"] as? [String] == ["*softonic.com"] })
        #expect(FilterListConverter.networkRules("||x.example^$domain=a.com|google.*", exception: false).count == 1)
    }

    @Test func adGuardContainsIsHasText() {
        #expect(CosmeticSelector.parse("div:contains(Advertisement)")
                == .procedural(ProceduralFilter(selector: "div", steps: [.init(type: "has-text", arg: "Advertisement")])))
    }

    @Test func badfilterAndSelectorChecksKeepSafeSelectorsOnly() {
        #expect(FilterListConverter.isSupportedSelector(".ad-banner"))
        #expect(!FilterListConverter.isSupportedSelector("div:has-text(ad)"))
    }
}

@Suite @MainActor struct ContentRuleCompilationTests {
    func compile(_ rules: [[String: Any]]) async throws -> WKContentRuleList? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(WKContentRuleListStore(url: dir))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        return try await store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: json)
    }

    /// WebKit rejects regexes outside its subset (e.g. "|"); the built-in list must compile.
    @Test func builtinListCompiles() async throws {
        #expect(try await compile(BuiltinBlocklist.rules) != nil)
    }

    /// Every rule shape the converter emits must be one WebKit accepts.
    @Test func everyConvertedShapeCompiles() async throws {
        let rules = FilterListConverter.convert(#"""
        ||doubleclick.net^$third-party
        ||cdn.example/ads/*.js$script
        |https://ads.example/banner|
        /ad-unit-
        /^https?:\/\/[a-z0-9]+\.example\/\d+\/ad\.js/$script
        ||ads.example^$subdocument,script
        ||popups.example^$popup
        ||cdn.example^$~script,~stylesheet
        ||t.example^$1p,xhr,domain=a.com|b.com
        ||t.example^$important
        @@||cdn.example/ads/allowed.js
        @@||bank.example^$document
        @@||blog.example^$generichide
        ##.adsbygoogle
        ##div:has(> .sponsored-label)
        ~example.com##.banner
        news.example##.promo-box
        example.com#@#.adsbygoogle
        0.0.0.0 tracker.example
        """#)
        #expect(try await compile(rules) != nil)
    }
}

/// Opt-in (network): LILY_TEST_FILTERLISTS=1 swift test --filter RealFilterListTests
/// Converts every list in the catalog and compiles every chunk with WebKit.
@Suite @MainActor struct RealFilterListTests {
    @Test func realListsConvertAndCompile() async throws {
        guard ProcessInfo.processInfo.environment["LILY_TEST_FILTERLISTS"] != nil else { return }
        var text = ""
        for list in FilterLists.all {
            for source in list.sources { text += String(decoding: try await URLSession.shared.data(from: source).0, as: UTF8.self) + "\n" }
        }
        var started = Date()
        let parsed = FilterListConverter.parse(text)
        let compiled = try FilterListConverter.compile(text)
        print("Filter lists: \(text.split(whereSeparator: \.isNewline).count) lines → \(compiled.ruleCount) rules in \(compiled.chunks.count) lists,"
              + " \(compiled.procedural.count) sites with procedural filters, \(parsed.skipped) skipped;"
              + " converted in \(String(format: "%.1f", Date().timeIntervalSince(started) / 2))s")
        #expect(compiled.ruleCount > 50_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-filterlists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(WKContentRuleListStore(url: dir))
        started = Date()
        for (index, json) in compiled.chunks.enumerated() {
            #expect(try await store.compileContentRuleList(forIdentifier: "chunk\(index)", encodedContentRuleList: json) != nil)
        }
        print("Compiled in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }
}
