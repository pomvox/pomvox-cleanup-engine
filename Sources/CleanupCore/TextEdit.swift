import Foundation

/// Half-open UTF-8 byte range in the exact original input; no normalization.
public struct TextEdit: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let replacement: String
    public init(start: Int, end: Int, replacement: String) {
        self.start = start; self.end = end; self.replacement = replacement
    }

    public func range(in original: String) throws -> Range<String.Index> {
        let bytes = original.utf8
        guard start >= 0, end >= start, end <= bytes.count,
              let lower = String.Index(bytes.index(bytes.startIndex, offsetBy: start), within: original.unicodeScalars),
              let upper = String.Index(bytes.index(bytes.startIndex, offsetBy: end), within: original.unicodeScalars)
        else { throw CleanupError.invalidEdits }
        return lower..<upper
    }

    public func utf16Range(in original: String) throws -> NSRange {
        let range = try range(in: original)
        return NSRange(location: range.lowerBound.utf16Offset(in: original),
                       length: range.upperBound.utf16Offset(in: original) - range.lowerBound.utf16Offset(in: original))
    }

    public static func applying(_ edits: [TextEdit], to original: String) throws -> String {
        var result: [UInt8] = []
        let bytes = Array(original.utf8)
        var cursor = 0
        for edit in edits {
            _ = try edit.range(in: original)
            guard edit.start >= cursor else { throw CleanupError.invalidEdits }
            result += bytes[cursor..<edit.start]
            result += edit.replacement.utf8
            cursor = edit.end
        }
        result += bytes[cursor...]
        guard let text = String(bytes: result, encoding: .utf8) else { throw CleanupError.invalidEdits }
        return text
    }

    /// One minimal contiguous replacement, bounded linear work. Not a semantic explanation.
    public static func between(_ original: String, and output: String) -> [TextEdit] {
        let a = Array(original.unicodeScalars), b = Array(output.unicodeScalars)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix].value == b[prefix].value { prefix += 1 }
        if prefix == a.count && prefix == b.count { return [] }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1].value == b[b.count - suffix - 1].value { suffix += 1 }
        func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            String(String.UnicodeScalarView(scalars))
        }
        return [TextEdit(start: string(a[..<prefix]).utf8.count,
                         end: string(a[..<(a.count - suffix)]).utf8.count,
                         replacement: string(b[prefix..<(b.count - suffix)]))]
    }
}
