import Foundation

/// A release version like "0.2.0" or "1.0.0-beta.2", ordered the semantic-versioning way:
/// numbers compared one by one (missing ones are zero), and a pre-release below the release
/// it leads up to. Tags may carry a leading "v".
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    /// "beta.2" in "1.0.0-beta.2"; empty for a release.
    public let prerelease: [String]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        // Build metadata ("+abc") never affects ordering.
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }
        let core: Substring
        if let dash = text.firstIndex(of: "-") {
            core = text[..<dash]
            prerelease = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        } else {
            core = Substring(text)
            prerelease = []
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
    }

    public var isPrerelease: Bool {
        !prerelease.isEmpty
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (isPrerelease ? "-" + prerelease.joined(separator: ".") : "")
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.last == 0 {
            trimmed.removeLast()
        }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0 ..< max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right {
                return left < right
            }
        }
        // Same numbers: a pre-release comes before the release.
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, false): return false
        case (true, false): return true
        case (false, true): return false
        case (true, true): return comparePrerelease(lhs.prerelease, rhs.prerelease)
        }
    }

    /// Identifier by identifier: numbers numerically and below words, words alphabetically,
    /// and a shorter list first when it's a prefix of the longer.
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.count < rhs.count
    }
}
