import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct FormDraftsTests {
    private let page = URL(string: "https://forum.example/thread/42?token=s3cret#reply")!
    private let reply = "A long reply that would hurt to lose if the tab crashed."

    @Test func keysPagesWithoutQueryOrFragment() {
        #expect(FormDrafts.pageKey(page) == "https://forum.example/thread/42")
        #expect(FormDrafts.pageKey(URL(string: "http://Example.com:8080")!) == "http://example.com:8080/")
        #expect(FormDrafts.pageKey(URL(string: "file:///tmp/a.html")!) == nil)
        #expect(FormDrafts.pageKey(URL(string: "about:blank")!) == nil)
    }

    @Test func keepsLongTextAndForgetsItWhenSentOrShortened() {
        let drafts = FormDrafts(directory: nil)
        drafts.save(page: page, field: "textarea#body", text: reply)
        // Same page, different query: the same draft.
        #expect(drafts.drafts(for: URL(string: "https://forum.example/thread/42")!).map(\.text) == [reply])
        #expect(drafts.drafts(for: URL(string: "https://forum.example/thread/43")!).isEmpty)

        drafts.save(page: page, field: "textarea#body", text: "too short")
        #expect(drafts.drafts(for: page).isEmpty)

        drafts.save(page: page, field: "textarea#body", text: reply)
        drafts.clear(page: page, field: "textarea#body")
        #expect(drafts.drafts.isEmpty)
    }

    @Test func credentialsAreNotKeptAsDrafts() {
        let drafts = FormDrafts(directory: nil)
        drafts.save(page: page, field: "textarea#body", text: reply)
        let secrets = [
            // Assembled at run time so the repository's secret scan doesn't flag these fakes.
            ["-----BEGIN OPENSSH", "PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\n-----END OPENSSH", "PRIVATE KEY-----"].joined(separator: " "),
            ["sk", "live", "4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c"].joined(separator: "-"),
            "  eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U\n",
            "abandon ability able about above absent absorb abstract absurd abuse access accident",
        ]
        for secret in secrets {
            #expect(FormDrafts.looksSecret(secret))
            drafts.save(page: page, field: "textarea#body", text: secret)
            // Typing a secret over a draft drops the draft too.
            #expect(drafts.drafts(for: page).isEmpty)
            drafts.save(page: page, field: "textarea#body", text: reply)
        }
        // Writing is kept, including twelve plain words with punctuation or capitals.
        for prose in [reply, "Thanks, this fixed it for me after the update broke my build again.",
                      "I think we should ship this on Monday after the review is done ok"] {
            #expect(!FormDrafts.looksSecret(prose))
        }
    }

    @Test func expiresAfterADayAndStaysBounded() {
        let drafts = FormDrafts(directory: nil)
        var clock = Date()
        drafts.now = { clock }
        drafts.save(page: page, field: "a", text: reply)
        clock = clock.addingTimeInterval(FormDrafts.lifetime + 1)
        #expect(drafts.drafts(for: page).isEmpty)

        for n in 0..<(FormDrafts.maxDrafts + 10) {
            drafts.save(page: URL(string: "https://site.example/\(n)")!, field: "a", text: reply)
        }
        #expect(drafts.drafts.count == FormDrafts.maxDrafts)
        #expect(drafts.drafts.first?.page == "https://site.example/\(FormDrafts.maxDrafts + 9)") // most recent kept

        drafts.save(page: page, field: "a", text: String(repeating: "word ", count: FormDrafts.maxCharacters / 5 + 100))
        #expect(drafts.drafts(for: page).first?.text.count == FormDrafts.maxCharacters)
    }

    @Test func encryptedAtRestAndClearedForGood() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = InMemoryKeyStore()
        let drafts = FormDrafts(directory: dir, keys: keys)
        drafts.save(page: page, field: "textarea#body", text: reply)
        await drafts.flush()

        let file = dir.appendingPathComponent("form-drafts.sealed")
        let raw = try Data(contentsOf: file)
        #expect(!String(decoding: raw, as: UTF8.self).contains("painful") && raw.range(of: Data(reply.utf8)) == nil)

        let reloaded = FormDrafts(directory: dir, keys: keys)
        await reloaded.load()
        #expect(reloaded.drafts(for: page).map(\.text) == [reply])

        reloaded.removeAll()
        await reloaded.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func payloadLimits() throws {
        #expect(try PagePayload.formDraft(field: "textarea#body", text: reply).field == "textarea#body")
        #expect(throws: IPCError.self) { try PagePayload.formDraft(field: "", text: reply) }
        #expect(throws: IPCError.self) { try PagePayload.formDraft(field: String(repeating: "f", count: 201), text: reply) }
        #expect(throws: IPCError.self) { try PagePayload.formDraft(field: "a", text: String(repeating: "x", count: FormDrafts.maxCharacters + 1)) }
    }
}
