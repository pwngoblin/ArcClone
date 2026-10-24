import Foundation
import Testing
@testable import LilyCore

@Suite struct HandoffContinueTests {
    @Test func onlyWebPagesAreContinued() {
        #expect(AppDelegate.continuable(URL(string: "https://example.com/a?b=1")) != nil)
        #expect(AppDelegate.continuable(URL(string: "http://example.com/")) != nil)
        #expect(AppDelegate.continuable(URL(string: "file:///etc/passwd")) == nil)
        #expect(AppDelegate.continuable(URL(string: "javascript:alert(1)")) == nil)
        #expect(AppDelegate.continuable(URL(string: "https:///no-host")) == nil)
        #expect(AppDelegate.continuable(nil) == nil)
    }
}
