import Foundation
import Testing
@testable import LilyCore

@Suite struct LinkTrackingTests {
    @Test func removesOnlyTrackingParameters() throws {
        let url = URL(string: "https://shop.example/item?id=42&utm_source=news&utm_Medium=mail&fbclid=IwAR0&q=red%20shoes&gclid=abc#reviews")!
        #expect(LinkTracking.stripped(url)?.absoluteString == "https://shop.example/item?id=42&q=red%20shoes#reviews")
    }

    @Test func leavesCleanAndOtherAddressesAlone() {
        #expect(LinkTracking.stripped(URL(string: "https://example.com/?page=2")!) == nil)
        #expect(LinkTracking.stripped(URL(string: "https://example.com/")!) == nil)
        #expect(LinkTracking.stripped(URL(string: "file:///tmp/a.html?utm_source=x")!) == nil)
        // A parameter that only looks like one isn't removed.
        #expect(LinkTracking.stripped(URL(string: "https://example.com/?gclid_like=1&ref=home")!) == nil)
    }

    @Test func dropsTheQueryWhenNothingElseIsLeft() {
        #expect(LinkTracking.stripped(URL(string: "https://example.com/a?utm_campaign=spring&mc_eid=1")!)?.absoluteString == "https://example.com/a")
    }

    @Test func keepsTheRestOfTheAddressExactly() {
        // Encoded characters, order and repeated keys survive untouched.
        let url = URL(string: "https://example.com/p?b=%2F%26&a=1&a=2&_ga=GA1.2&x=%E2%9C%93")!
        #expect(LinkTracking.stripped(url)?.absoluteString == "https://example.com/p?b=%2F%26&a=1&a=2&x=%E2%9C%93")
    }

    @Test func importsUseTheSameList() throws {
        let cleaned = try #require(URLNormalizer.clean(URL(string: "https://Example.com/x/?utm_source=a&id=1&fbclid=z")!))
        #expect(cleaned.absoluteString == "https://example.com/x?id=1")
    }
}
