import Foundation
import Testing
@testable import ArcCloneCore

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

        drafts.save(page: page, field: "a", text: String(repeating: "x", count: FormDrafts.maxCharacters + 500))
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
