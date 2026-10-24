import AppKit

/// All clipboard writes go through here. Copies from private windows (and anything marked
/// sensitive) carry the nspasteboard.org Concealed/Transient markers, which clipboard managers and
/// sync tools honor by not recording or syncing the item.
@MainActor
enum Clipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(_ string: String, sensitive: Bool, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if sensitive {
            pasteboard.declareTypes([.string, concealed, transient], owner: nil)
            pasteboard.setString("", forType: concealed)
            pasteboard.setString("", forType: transient)
        }
        pasteboard.setString(string, forType: .string)
    }
}
