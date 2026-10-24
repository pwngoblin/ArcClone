import Foundation

/// Escaping and validation for data that crosses into another language or the file system.
enum Sanitize {
    static let maxErrorLength = 300

    /// Error text that is safe to show in the UI or hand to page scripts: our own IPC messages as
    /// they are; system errors by their localized description with file paths and file URLs
    /// replaced; and nothing from Swift errors whose description is a type dump. Details belong in
    /// the private log, never on screen.
    static func errorMessage(_ error: Error) -> String {
        if let ipc = error as? IPCError { return String(ipc.message.prefix(maxErrorLength)) }
        var text = error.localizedDescription
        // Errors with no description of their own read "The operation couldn’t be completed.
        // (Module.TypeName error 1.)": internal type names and nothing useful for the user.
        if text.range(of: #"\([^()]+ error -?\d+\.\)$"#, options: .regularExpression) != nil { return "Something went wrong." }
        text = text.replacingOccurrences(of: #"file://\S+"#, with: "a file", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![\w:])(/(Users|private|var|tmp|Volumes|Applications|Library|System)(/[^\s“”"'’,;)]*)?)"#,
                                         with: "a location on this Mac", options: .regularExpression)
        return String(text.prefix(maxErrorLength))
    }

    /// HTML text and attribute content (both quote styles).
    static func html(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(char)
            }
        }
        return out
    }

    /// Bidi overrides/isolates and other invisible format characters, used to disguise text,
    /// e.g. "invoice\u{202E}fdp.app" displaying as "invoiceppa.pdf".
    static func isInvisibleControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F: return true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    /// A download name that can't escape the folder, hide itself, or lie about its extension.
    static func filename(_ suggested: String, fallback: String = "download") -> String {
        var view = String.UnicodeScalarView()
        for scalar in suggested.unicodeScalars where !isInvisibleControl(scalar) && scalar != "\n" && scalar != "\r" && scalar != "\t" {
            view.append(scalar == "/" || scalar == ":" || scalar == "\\" ? "_" : scalar)
        }
        var name = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() } // no hidden files, no "..", no "."
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let keep = String(base.prefix(180))
            name = ext.isEmpty || ext.count > 15 ? keep : "\(keep).\(ext)"
        }
        return name.isEmpty ? fallback : name
    }

    /// Favicons are fetched by the app itself, outside WebKit's protections, so only HTTPS to public
    /// hosts: never loopback/LAN devices (request forgery), never embedded credentials.
    static func isFetchableFavicon(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host, url.user == nil, url.password == nil else { return false }
        return !HTTPSFirst.isPrivate(host)
    }
}
