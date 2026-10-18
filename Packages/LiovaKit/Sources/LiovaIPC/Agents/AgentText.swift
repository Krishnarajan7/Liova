import Foundation

/// Text clean-up shared by the agent hook adapters.
///
/// Hook input comes from tools we don't control, so every string that reaches Liova is
/// trimmed to the wire limits here instead of failing validation later.
public enum AgentText {
    /// The marker appended to text that was cut short.
    public static let ellipsis: Character = "…"

    /// `text` cut to at most `maxCharacters` characters **and** `maxBytes` UTF-8 bytes, ending
    /// in "…" when anything was removed.
    ///
    /// The byte cap matters for hostile input: one "character" (grapheme cluster) can hold any
    /// number of combining scalars, so a character limit alone doesn't bound the request size.
    public static func truncate(_ text: String, maxCharacters: Int, maxBytes: Int = .max) -> String {
        guard maxCharacters > 0, maxBytes > 0 else { return "" }
        let ellipsisBytes = String(ellipsis).utf8.count
        var characters = 0
        var bytes = 0
        var cut: String.Index?
        // Where the text would end if an ellipsis has to be added.
        var lastFitWithEllipsis = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if characters + 1 <= maxCharacters - 1, bytes + size <= maxBytes - ellipsisBytes {
                lastFitWithEllipsis = text.index(after: index)
            }
            characters += 1
            bytes += size
            if characters > maxCharacters || bytes > maxBytes {
                cut = lastFitWithEllipsis
                break
            }
        }
        guard let cut else { return text }
        guard maxBytes >= ellipsisBytes else { return "" }
        return String(text[..<cut]) + String(ellipsis)
    }

    /// `text` on one line: control characters and line breaks become spaces, runs of
    /// whitespace collapse to one space, and the ends are trimmed.
    public static func singleLine(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            let visible = character.isWhitespace || character.isNewline ? nil : withoutControls(character)
            guard let visible else {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(contentsOf: visible)
        }
        return result
    }

    /// `text` with control characters removed, except newlines and tabs. Used for text shown
    /// verbatim, such as a shell command awaiting approval.
    public static func removingControlCharacters(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            if character == "\n" || character == "\t" || character == "\r\n" {
                result.append(character == "\r\n" ? "\n" : character)
            } else if let visible = withoutControls(character) {
                result.append(contentsOf: visible)
            }
        }
        return result
    }

    /// The first line of `text` that isn't blank, trimmed.
    public static func firstNonBlankLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// The last path component of a file path or `cwd`, or `nil` for an empty path or `/`.
    public static func lastPathComponent(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let component = trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        guard let component, !component.isEmpty else { return nil }
        return component
    }

    /// `character` without control and format scalars (bidi overrides, zero-width spaces...),
    /// or `nil` if nothing visible is left. Filtering scalars, not whole characters, matters:
    /// a bidi override followed by a combining mark forms one character that would otherwise
    /// slip through. Zero-width joiners inside emoji sequences are kept.
    private static func withoutControls(_ character: Character) -> String? {
        let scalars = character.unicodeScalars
        guard scalars.contains(where: isControl) else { return String(character) }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars.filter { !isControl($0) })
        return kept.isEmpty ? nil : String(kept)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control: true
        case .format: scalar.value != 0x200D
        default: false
        }
    }
}
