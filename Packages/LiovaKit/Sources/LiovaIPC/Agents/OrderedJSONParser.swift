import Foundation

/// A strict recursive-descent JSON parser over UTF-8 bytes.
struct OrderedJSONParser {
    static let maxDepth = 100
    static let simpleEscapes: [UInt8: Unicode.Scalar] = [
        UInt8(ascii: "\""): "\"", UInt8(ascii: "\\"): "\\", UInt8(ascii: "/"): "/", UInt8(ascii: "b"): "\u{08}",
        UInt8(ascii: "f"): "\u{0C}", UInt8(ascii: "n"): "\n", UInt8(ascii: "r"): "\r", UInt8(ascii: "t"): "\t",
    ]

    let bytes: [UInt8]
    var position = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            position = 3
        }
    }

    mutating func parseDocument() throws(OrderedJSON.ParseError) -> OrderedJSON {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard position == bytes.count else { throw error("Unexpected text after the JSON value") }
        return value
    }

    private mutating func parseValue() throws(OrderedJSON.ParseError) -> OrderedJSON {
        guard position < bytes.count else { throw error("Unexpected end of input") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return try .string(parseString())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return try parseNumber()
        default: throw error("Unexpected character")
        }
    }

    private mutating func parseObject() throws(OrderedJSON.ParseError) -> OrderedJSON {
        try enter()
        defer { depth -= 1 }
        position += 1
        var members: [OrderedJSON.Member] = []
        skipWhitespace()
        if consume(UInt8(ascii: "}")) {
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                throw error("Expected a string key")
            }
            let key = try parseString()
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw error("Expected ':' after a key") }
            skipWhitespace()
            let value = try parseValue()
            // A repeated key keeps its first position but takes the last value, like JSON.parse.
            if let index = members.firstIndex(where: { $0.key == key }) {
                members[index].value = value
            } else {
                members.append(OrderedJSON.Member(key, value))
            }
            skipWhitespace()
            if consume(UInt8(ascii: ",")) {
                continue
            }
            guard consume(UInt8(ascii: "}")) else { throw error("Expected ',' or '}' in an object") }
            return .object(members)
        }
    }

    private mutating func parseArray() throws(OrderedJSON.ParseError) -> OrderedJSON {
        try enter()
        defer { depth -= 1 }
        position += 1
        var elements: [OrderedJSON] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) {
            return .array(elements)
        }
        while true {
            skipWhitespace()
            try elements.append(parseValue())
            skipWhitespace()
            if consume(UInt8(ascii: ",")) {
                continue
            }
            guard consume(UInt8(ascii: "]")) else { throw error("Expected ',' or ']' in an array") }
            return .array(elements)
        }
    }

    private mutating func parseString() throws(OrderedJSON.ParseError) -> String {
        position += 1 // Opening quote.
        var scalars = String.UnicodeScalarView()
        var runStart = position
        func flushRun(_ end: Int) throws(OrderedJSON.ParseError) {
            guard runStart < end else { return }
            guard let text = String(bytes: bytes[runStart ..< end], encoding: .utf8) else {
                throw error("Invalid UTF-8 in a string")
            }
            scalars.append(contentsOf: text.unicodeScalars)
        }
        while position < bytes.count {
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "\""):
                try flushRun(position)
                position += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                try flushRun(position)
                position += 1
                try scalars.append(parseEscape())
                runStart = position
            case 0x00 ..< 0x20:
                throw error("Unescaped control character in a string")
            default:
                position += 1
            }
        }
        throw error("Unterminated string")
    }

    private mutating func parseEscape() throws(OrderedJSON.ParseError) -> Unicode.Scalar {
        guard position < bytes.count else { throw error("Unterminated escape") }
        let byte = bytes[position]
        position += 1
        if byte == UInt8(ascii: "u") {
            return try parseUnicodeEscape()
        }
        guard let scalar = Self.simpleEscapes[byte] else {
            position -= 1
            throw error("Invalid escape")
        }
        return scalar
    }

    /// The scalar for `\uXXXX`, or a surrogate pair like `\uD83D\uDE00`, after the `u`.
    private mutating func parseUnicodeEscape() throws(OrderedJSON.ParseError) -> Unicode.Scalar {
        let unit = try parseHex4()
        if UTF16.isLeadSurrogate(unit) {
            guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else {
                throw error("Unpaired surrogate in a \\u escape")
            }
            let trail = try parseHex4()
            guard UTF16.isTrailSurrogate(trail) else { throw error("Unpaired surrogate in a \\u escape") }
            let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { throw error("Invalid \\u escape") }
            return scalar
        }
        guard let scalar = Unicode.Scalar(unit) else { throw error("Unpaired surrogate in a \\u escape") }
        return scalar
    }

    private mutating func parseHex4() throws(OrderedJSON.ParseError) -> UInt16 {
        guard position + 4 <= bytes.count else { throw error("Incomplete \\u escape") }
        var value: UInt16 = 0
        for _ in 0 ..< 4 {
            let byte = bytes[position]
            let digit: UInt8 = switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: throw error("Invalid hex digit in a \\u escape")
            }
            value = value << 4 | UInt16(digit)
            position += 1
        }
        return value
    }

    private mutating func parseNumber() throws(OrderedJSON.ParseError) -> OrderedJSON {
        let start = position
        _ = consume(UInt8(ascii: "-"))
        if consume(UInt8(ascii: "0")) {
            // A leading zero can't be followed by more digits.
        } else {
            guard digits() > 0 else { throw error("Invalid number") }
        }
        if consume(UInt8(ascii: ".")) {
            guard digits() > 0 else { throw error("Expected digits after '.'") }
        }
        if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
            _ = consume(UInt8(ascii: "+")) || consume(UInt8(ascii: "-"))
            guard digits() > 0 else { throw error("Expected digits in an exponent") }
        }
        if position < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[position]) {
            throw error("Invalid number")
        }
        // Only ASCII digits and signs got here, so the bytes are always valid UTF-8.
        return .number(String(bytes: bytes[start ..< position], encoding: .utf8) ?? "0")
    }

    private mutating func digits() -> Int {
        let start = position
        while position < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[position]) {
            position += 1
        }
        return position - start
    }

    private mutating func literal(_ word: String, _ value: OrderedJSON) throws(OrderedJSON.ParseError) -> OrderedJSON {
        let expected = Array(word.utf8)
        guard bytes[position...].starts(with: expected) else { throw error("Unexpected character") }
        position += expected.count
        return value
    }

    private mutating func enter() throws(OrderedJSON.ParseError) {
        depth += 1
        guard depth <= Self.maxDepth else { throw error("Nesting is deeper than \(Self.maxDepth) levels") }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    private mutating func skipWhitespace() {
        while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) {
            position += 1
        }
    }

    private func error(_ message: String) -> OrderedJSON.ParseError {
        var line = 1
        var column = 1
        for byte in bytes[..<min(position, bytes.count)] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return OrderedJSON.ParseError(message: message, line: line, column: column)
    }
}
