import Foundation
@testable import LiovaIPC
import Testing

@Suite("Agent text helpers")
struct AgentTextTests {
    @Test func truncateKeepsShortTextAndMarksCuts() {
        #expect(AgentText.truncate("hello", maxCharacters: 5) == "hello")
        #expect(AgentText.truncate("hello!", maxCharacters: 5) == "hell…")
        #expect(AgentText.truncate("hello", maxCharacters: 1) == "…")
        #expect(AgentText.truncate("hello", maxCharacters: 0) == "")
        #expect(AgentText.truncate("", maxCharacters: 3) == "")
    }

    @Test func truncateHonoursTheByteLimit() {
        let text = String(repeating: "é", count: 10) // 2 bytes each
        let cut = AgentText.truncate(text, maxCharacters: 100, maxBytes: 9)
        #expect(cut.utf8.count <= 9)
        #expect(cut == "ééé…")
        // One enormous grapheme cluster can't be split, so it is dropped entirely.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 1000)
        #expect(AgentText.truncate(zalgo, maxCharacters: 100, maxBytes: 100) == "…")
    }

    @Test func singleLineCollapsesWhitespaceAndControls() {
        #expect(AgentText.singleLine("  a\n\tb \u{1B}[0m  c\r\n") == "a b [0m c")
        #expect(AgentText.singleLine("left\u{202E}right") == "left right")
        #expect(AgentText.singleLine("👨‍👩‍👧") == "👨‍👩‍👧")
    }

    @Test func removingControlCharactersKeepsLinesAndTabs() {
        #expect(AgentText.removingControlCharacters("a\r\nb\tc\u{7}\u{202E}d") == "a\nb\tcd")
    }

    @Test func pathAndLineHelpers() {
        #expect(AgentText.lastPathComponent("/Users/me/Projects/App/") == "App")
        #expect(AgentText.lastPathComponent("/") == nil)
        #expect(AgentText.lastPathComponent("") == nil)
        #expect(AgentText.lastPathComponent("file.txt") == "file.txt")
        #expect(AgentText.firstNonBlankLine("\n  \n  ls -la  \nnext") == "ls -la")
        #expect(AgentText.firstNonBlankLine(" \n ") == nil)
    }
}

@Suite("Shell words")
struct AgentShellWordsTests {
    @Test func quoting() {
        #expect(ShellWords.quote("/usr/local/bin/liova") == "/usr/local/bin/liova")
        #expect(ShellWords.quote("/Applications/My Apps/liova") == "'/Applications/My Apps/liova'")
        #expect(ShellWords.quote("/tmp/it's") == #"'/tmp/it'\''s'"#)
        #expect(ShellWords.quote("/tmp/$HOME") == "'/tmp/$HOME'")
        #expect(ShellWords.quote("") == "''")
    }

    @Test(arguments: [
        ("/usr/bin/liova hook claude-code", "/usr/bin/liova", " hook claude-code"),
        ("'/My Apps/liova' hook", "/My Apps/liova", " hook"),
        (#"'/tmp/it'\''s/liova' x"#, "/tmp/it's/liova", " x"),
        (#""/a b/liova" x"#, "/a b/liova", " x"),
        (#"/a\ b/liova x"#, "/a b/liova", " x"),
        (#""/a\"b\$c\d""#, #"/a"b$c\d"#, ""),
        ("  liova", "liova", ""),
    ])
    func firstWord(command: String, word: String, rest: String) throws {
        let parsed = try #require(ShellWords.firstWord(of: command))
        #expect(parsed.word == word)
        #expect(String(parsed.rest) == rest)
    }

    @Test func firstWordRejectsBadInput() {
        #expect(ShellWords.firstWord(of: "") == nil)
        #expect(ShellWords.firstWord(of: "   ") == nil)
        #expect(ShellWords.firstWord(of: "'unterminated") == nil)
    }

    @Test func quotedPathsRoundTrip() throws {
        let paths = ["/Applications/Liova.app/Contents/MacOS/liova", "/Users/a b/it's \"here\"/liova", "/ü/€/liova"]
        for path in paths {
            let parsed = try #require(ShellWords.firstWord(of: ShellWords.quote(path) + " hook claude-code"))
            #expect(parsed.word == path)
        }
    }
}

@Suite("Ordered JSON")
struct AgentOrderedJSONTests {
    @Test func keepsKeyOrderAndNumberLiterals() throws {
        let text = #"{"zeta": 1.50, "alpha": [true, false, null, -0, 1e3, 2E-2], "mid": {"b": "x", "a": "y"}}"#
        let value = try OrderedJSON.parse(Data(text.utf8))
        #expect(value.members?.map(\.key) == ["zeta", "alpha", "mid"])
        #expect(value["zeta"] == .number("1.50"))
        #expect(value["mid"]?.members?.map(\.key) == ["b", "a"])
        #expect(value.prettyPrinted() == """
        {
          "zeta": 1.50,
          "alpha": [
            true,
            false,
            null,
            -0,
            1e3,
            2E-2
          ],
          "mid": {
            "b": "x",
            "a": "y"
          }
        }

        """)
    }

    @Test func stringsRoundTripThroughFoundation() throws {
        let original = "quote \" slash / back \\ tab \t nl \n ctl \u{1} é 😀 \u{2028}"
        let json = try JSONSerialization.data(withJSONObject: ["k": original])
        let parsed = try OrderedJSON.parse(json)
        #expect(parsed["k"] == .string(original))
        let reparsed = try JSONSerialization.jsonObject(with: Data(parsed.prettyPrinted().utf8)) as? [String: String]
        #expect(reparsed?["k"] == original)
        let escaped = try OrderedJSON.parse(Data(#"["\u00e9\ud83d\ude00\/"]"#.utf8))
        #expect(escaped == .array([.string("é😀/")]))
    }

    @Test func emptyContainersAndBOM() throws {
        let value = try OrderedJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array(#"{"a":{},"b":[]}"#.utf8)))
        #expect(value.prettyPrinted() == "{\n  \"a\": {},\n  \"b\": []\n}\n")
    }

    @Test func duplicateKeysKeepTheFirstPositionAndLastValue() throws {
        let value = try OrderedJSON.parse(Data(#"{"a":1,"b":2,"a":3}"#.utf8))
        #expect(value == .object([.init("a", .number("3")), .init("b", .number("2"))]))
    }

    @Test(arguments: [
        "", "{", "{\"a\":}", "{\"a\" 1}", "[1,]", "{\"a\":1,}", "01", "1.", "-", "1e", "tru", "\"\\x\"",
        "\"\u{1}\"", "\"\\ud800\"", "{} {}", "{'a': 1}", "// comment\n{}", "NaN", "\"abc",
    ])
    func rejectsInvalidJSON(text: String) {
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(text.utf8)) }
    }

    @Test func rejectsInvalidUTF8AndDeepNesting() {
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data([0x22, 0xFF, 0x22])) }
        let deep = String(repeating: "[", count: 10000) + String(repeating: "]", count: 10000)
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(deep.utf8)) }
    }

    @Test func errorsReportTheLine() {
        do {
            _ = try OrderedJSON.parse(Data("{\n  \"a\": 1,\n  oops\n}".utf8))
            Issue.record("Expected an error")
        } catch {
            #expect(error.line == 3)
            #expect(error.column == 3)
        }
    }

    @Test func setReplacesInPlaceAppendsAndRemoves() {
        var value = OrderedJSON.object([.init("a", .number("1")), .init("b", .number("2"))])
        value.set("a", .bool(true))
        value.set("c", .null)
        value.set("b", nil)
        #expect(value == .object([.init("a", .bool(true)), .init("c", .null)]))
    }
}
