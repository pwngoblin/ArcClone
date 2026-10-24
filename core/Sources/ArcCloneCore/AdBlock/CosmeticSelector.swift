import Foundation

/// A cosmetic filter WebKit can't express on its own: a CSS selector narrowed by steps that run
/// in the page (`injections/modules/cosmetic-filter.js`), e.g. `div.post:has-text(Sponsored):upward(2)`.
/// Steps are data — matched text and selectors — never code.
public struct ProceduralFilter: Codable, Sendable, Hashable {
    public struct Step: Codable, Sendable, Hashable {
        /// "has-text" (plain text or /regex/flags), "min-text-length" (a number) or "upward"
        /// (a number of levels or a selector for closest()).
        public let type: String
        public let arg: String
    }

    public let selector: String
    public let steps: [Step]
    /// `:style(…)`: declarations to set on the matches instead of hiding them, from a fixed list of
    /// layout properties (typically restoring scrolling under a removed cookie wall).
    public var style: String?

    public init(selector: String, steps: [Step], style: String? = nil) {
        self.selector = selector
        self.steps = steps
        self.style = style
    }
}

/// The selector half of an element-hiding filter (`domains##selector`), classified and checked.
enum CosmeticSelector: Equatable {
    case css(String)
    case procedural(ProceduralFilter)

    static let maxLength = 500
    static let maxTextArgument = 200

    /// Pseudo-classes WebKit's content blockers accept. Anything else (uBlock Origin or AdGuard
    /// extensions such as `:matches-css`, or a typo) is refused here, because one bad selector in a
    /// batch makes WebKit drop the whole rule.
    static let pseudoClasses: Set<String> = [
        "not", "is", "where", "has", "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type",
        "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type",
        "empty", "root", "checked", "disabled", "enabled", "link", "any-link", "target", "lang", "dir",
        "placeholder-shown", "required", "optional", "read-only", "read-write", "defined", "scope",
    ]
    static let proceduralOperators: Set<String> = ["has-text", "min-text-length", "upward", "remove", "style"]
    /// Properties `:style()` may set. Nothing that loads resources (backgrounds, content, fonts)
    /// or could overlay fake content: only visibility, layout and scrolling.
    static let styleProperties: Set<String> = [
        "display", "visibility", "opacity", "overflow", "overflow-x", "overflow-y", "overscroll-behavior", "position",
        "top", "right", "bottom", "left", "inset", "width", "height", "min-width", "min-height", "max-width", "max-height",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left", "padding", "padding-top", "padding-right",
        "padding-bottom", "padding-left", "z-index", "transform", "filter", "-webkit-filter", "backdrop-filter",
        "-webkit-backdrop-filter", "pointer-events", "user-select", "-webkit-user-select", "touch-action", "clip-path",
    ]

    /// nil: unsupported (scriptlets, CSS injection, HTML filtering, unknown operators).
    static func parse(_ raw: String) -> CosmeticSelector? {
        let body = raw.replacingOccurrences(of: ":-abp-contains(", with: ":has-text(")
            .replacingOccurrences(of: ":contains(", with: ":has-text(")
            .replacingOccurrences(of: ":-abp-has(", with: ":has(")
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, body.count <= maxLength, !body.hasPrefix("+js("), !body.hasPrefix("^") else { return nil }
        guard let start = firstProceduralOperator(in: body) else {
            return isValidCSS(body) ? .css(body) : nil
        }
        let base = String(body[..<start]).trimmingCharacters(in: .whitespaces)
        guard isValidCSS(base), let (steps, style) = parseSteps(body[start...]) else { return nil }
        if steps.isEmpty && style == nil { return .css(base) }
        return .procedural(ProceduralFilter(selector: base, steps: steps, style: style))
    }

    /// A selector that is safe to hand to WebKit's `css-display-none`, which builds
    /// `selector { display: none !important }`. Outside quoted strings, braces, semicolons and
    /// at-rules could smuggle extra CSS (e.g. tracking backgrounds) into every page, so they're
    /// refused; escapes (`.h-\[90px\]`) can't end a token and are fine, except a trailing one that
    /// would escape WebKit's own brace.
    static func isValidCSS(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= maxLength, !selector.lowercased().contains("url("),
              selector.rangeOfCharacter(from: CharacterSet(charactersIn: "{}<\n\r\u{0}")) == nil else { return false }
        var quote: Character?
        var bracketDepth = 0
        var parenDepth = 0
        var index = selector.startIndex
        while index < selector.endIndex {
            let char = selector[index]
            if char == "\\" {
                index = selector.index(after: index)
                guard index < selector.endIndex else { return false }
            } else if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == ";" || char == "@" {
                return false
            } else if char == "[" {
                bracketDepth += 1
            } else if char == "]" {
                bracketDepth -= 1
                if bracketDepth < 0 { return false }
            } else if bracketDepth == 0, char == "(" {
                parenDepth += 1
            } else if bracketDepth == 0, char == ")" {
                parenDepth -= 1
                if parenDepth < 0 { return false }
            } else if bracketDepth == 0, char == ":" {
                let next = selector.index(after: index)
                if next < selector.endIndex, selector[next] == ":" { return false } // pseudo-elements
                let name = selector[next...].prefix { $0.isLetter || $0 == "-" }
                guard pseudoClasses.contains(name.lowercased()) else { return false }
            }
            index = selector.index(after: index)
        }
        return quote == nil && bracketDepth == 0 && parenDepth == 0
    }

    /// Index of the first `:operator(` outside brackets, quotes and parentheses.
    private static func firstProceduralOperator(in body: String) -> String.Index? {
        var quote: Character?
        var depth = 0
        var index = body.startIndex
        while index < body.endIndex {
            let char = body[index]
            if char == "\\" {
                index = body.index(after: index)
                if index == body.endIndex { return nil }
            } else if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "[" || char == "(" {
                depth += 1
            } else if char == "]" || char == ")" {
                depth -= 1
            } else if depth == 0, char == ":" {
                let name = body[body.index(after: index)...].prefix { $0.isLetter || $0 == "-" }
                if proceduralOperators.contains(String(name)) { return index }
            }
            index = body.index(after: index)
        }
        return nil
    }

    /// `:has-text(x):upward(2)` → steps (and a final `:style(…)`). Anything after an operator must
    /// be another operator.
    private static func parseSteps(_ text: Substring) -> ([ProceduralFilter.Step], String?)? {
        var steps: [ProceduralFilter.Step] = []
        var style: String?
        var rest = text
        while !rest.isEmpty {
            guard style == nil else { return nil }
            guard rest.first == ":" else { return nil }
            let name = String(rest.dropFirst().prefix { $0.isLetter || $0 == "-" })
            rest = rest.dropFirst(1 + name.count)
            guard rest.first == "(", let (argument, after) = balancedArgument(rest) else { return nil }
            rest = after
            switch name {
            case "has-text":
                guard !argument.isEmpty, argument.count <= maxTextArgument, isValidTextArgument(argument) else { return nil }
                steps.append(.init(type: "has-text", arg: argument))
            case "min-text-length":
                guard let count = Int(argument), (1...10_000).contains(count) else { return nil }
                steps.append(.init(type: "min-text-length", arg: String(count)))
            case "upward":
                if let levels = Int(argument) {
                    guard (1...32).contains(levels) else { return nil }
                    steps.append(.init(type: "upward", arg: String(levels)))
                } else {
                    guard isValidCSS(argument) else { return nil }
                    steps.append(.init(type: "upward", arg: argument))
                }
            case "remove":
                guard argument.isEmpty, rest.isEmpty else { return nil } // hidden rather than removed
            case "style":
                guard let declarations = styleDeclarations(argument) else { return nil }
                style = declarations
            default:
                return nil
            }
        }
        return (steps, style)
    }

    /// `overflow: auto !important; position: static` → normalized declarations, or nil when any
    /// property is outside `styleProperties` or a value could do more than set a length or keyword.
    static func styleDeclarations(_ text: String) -> String? {
        guard text.count <= maxTextArgument else { return nil }
        var declarations: [String] = []
        for part in text.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let property = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasSuffix("!important") { value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces) }
            let lowered = value.lowercased()
            guard styleProperties.contains(property), !value.isEmpty,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " .,%#()+-/".contains($0)) }),
                  !["url(", "image", "expression", "attr(", "var(", "env("].contains(where: lowered.contains) else { return nil }
            declarations.append("\(property): \(value)")
        }
        return declarations.isEmpty ? nil : declarations.joined(separator: "; ")
    }

    /// `(…)` with nested parentheses (regexes often have them); returns the inside and what follows.
    private static func balancedArgument(_ text: Substring) -> (String, Substring)? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "\\": index = text.index(after: index) // skip the escaped character
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    let inside = text[text.index(after: text.startIndex)..<index]
                    return (String(inside), text[text.index(after: index)...])
                }
            default: break
            }
            guard index < text.endIndex else { break }
            index = text.index(after: index)
        }
        return nil
    }

    /// Plain text, or `/regex/flags` with only i, m, s, u flags.
    private static func isValidTextArgument(_ argument: String) -> Bool {
        guard argument.hasPrefix("/"), let close = argument.lastIndex(of: "/"), close != argument.startIndex else { return true }
        let flags = argument[argument.index(after: close)...]
        return flags.allSatisfy { "imsu".contains($0) } && argument.distance(from: argument.startIndex, to: close) > 1
    }
}
