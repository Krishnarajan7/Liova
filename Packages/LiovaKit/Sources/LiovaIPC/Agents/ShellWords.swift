/// Minimal POSIX shell quoting, for hook commands that agents run through `sh -c`.
public enum ShellWords {
    /// `word` as one shell word: unchanged when it only uses safe characters, otherwise in
    /// single quotes (with embedded single quotes written as `'\''`).
    public static func quote(_ word: String) -> String {
        guard word.isEmpty || !word.unicodeScalars.allSatisfy(isSafe) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The first word of a command line with quotes and escapes removed, plus the text after
    /// it. Handles single quotes, double quotes and backslashes; `nil` for an empty line or an
    /// unterminated quote.
    public static func firstWord(of command: String) -> (word: String, rest: Substring)? {
        var index = command.startIndex
        while index < command.endIndex, command[index] == " " || command[index] == "\t" {
            index = command.index(after: index)
        }
        guard index < command.endIndex else { return nil }
        var word = ""
        var quote: Character?
        while index < command.endIndex {
            let character = command[index]
            index = command.index(after: index)
            switch (quote, character) {
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                return (word, command[command.index(before: index)...])
            case (nil, "'"), (nil, "\""):
                quote = character
            case (nil, "\\"), ("\"", "\\"):
                guard index < command.endIndex else { return (word, command[index...]) }
                let next = command[index]
                // Inside double quotes a backslash only escapes a few characters.
                if quote == "\"", !["\"", "\\", "$", "`"].contains(next) {
                    word.append("\\")
                } else {
                    word.append(next)
                    index = command.index(after: index)
                }
            case let (open?, character) where character == open:
                quote = nil
            default:
                word.append(character)
            }
        }
        return quote == nil ? (word, command[command.endIndex...]) : nil
    }

    private static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a" ... "z", "A" ... "Z", "0" ... "9", "/", ".", "_", "-", "+", "@", "%", ":", ",", "=": true
        default: false
        }
    }
}
