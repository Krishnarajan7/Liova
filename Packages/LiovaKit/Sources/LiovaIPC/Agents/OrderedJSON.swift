import Foundation

/// A JSON value that keeps object keys in their original order and numbers exactly as
/// written, so editing one part of a user's config file leaves the rest byte-for-byte
/// recognisable (apart from whitespace).
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// The number's literal text, e.g. `1e3` or `0.10`, kept as written.
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    /// Why a document couldn't be parsed.
    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public var message: String
        /// 1-based line and column of the problem.
        public var line: Int
        public var column: Int

        public var description: String {
            "\(message) at line \(line), column \(column)"
        }
    }

    // MARK: Access

    /// The members of an object, or `nil` for any other value.
    public var members: [Member]? {
        if case let .object(members) = self {
            members
        } else {
            nil
        }
    }

    /// The elements of an array, or `nil` for any other value.
    public var elements: [OrderedJSON]? {
        if case let .array(elements) = self {
            elements
        } else {
            nil
        }
    }

    public var stringValue: String? {
        if case let .string(text) = self {
            text
        } else {
            nil
        }
    }

    /// The value for `key` in an object (the last one, if a key repeats, as JavaScript does).
    public subscript(key: String) -> OrderedJSON? {
        members?.last { $0.key == key }?.value
    }

    /// Sets `key` in an object, keeping its position if it exists and appending it otherwise.
    /// `nil` removes the key. Does nothing on a non-object.
    public mutating func set(_ key: String, _ value: OrderedJSON?) {
        guard var members else { return }
        if let value {
            if let index = members.lastIndex(where: { $0.key == key }) {
                members[index].value = value
            } else {
                members.append(Member(key, value))
            }
        } else {
            members.removeAll { $0.key == key }
        }
        self = .object(members)
    }

    // MARK: Parsing

    /// Parses a complete JSON document (RFC 8259). A UTF-8 byte order mark is skipped.
    public static func parse(_ data: Data) throws(ParseError) -> OrderedJSON {
        var parser = OrderedJSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    // MARK: Writing

    /// Pretty-printed JSON with two-space indentation and `"key": value`, ending in a newline.
    public func prettyPrinted() -> String {
        var output = ""
        write(to: &output, indent: 0)
        output.append("\n")
        return output
    }

    private func write(to output: inout String, indent: Int) {
        switch self {
        case let .object(members):
            guard !members.isEmpty else {
                output.append("{}")
                return
            }
            output.append("{\n")
            for (index, member) in members.enumerated() {
                output.append(String(repeating: "  ", count: indent + 1))
                Self.writeString(member.key, to: &output)
                output.append(": ")
                member.value.write(to: &output, indent: indent + 1)
                output.append(index == members.count - 1 ? "\n" : ",\n")
            }
            output.append(String(repeating: "  ", count: indent) + "}")
        case let .array(elements):
            guard !elements.isEmpty else {
                output.append("[]")
                return
            }
            output.append("[\n")
            for (index, element) in elements.enumerated() {
                output.append(String(repeating: "  ", count: indent + 1))
                element.write(to: &output, indent: indent + 1)
                output.append(index == elements.count - 1 ? "\n" : ",\n")
            }
            output.append(String(repeating: "  ", count: indent) + "]")
        case let .string(text):
            Self.writeString(text, to: &output)
        case let .number(literal):
            output.append(literal)
        case let .bool(value):
            output.append(value ? "true" : "false")
        case .null:
            output.append("null")
        }
    }

    private static func writeString(_ text: String, to output: inout String) {
        output.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            case "\u{08}": output.append("\\b")
            case "\u{0C}": output.append("\\f")
            case _ where scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029:
                output.append(String(format: "\\u%04x", scalar.value))
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
    }
}
