import Foundation

/// Spelling variants of one dictionary term: auxiliary generation on the resident
/// pack with a prompt the pack owns. The term is bounded like a vocabulary term.
public struct VariantRequest: Sendable {
    public let term: String
    public let limit: Int
    public let deadline: Duration?

    /// The app's defaults: six chips, and `CleanupEngine.suggestVariants(timeoutS: 8.0)`.
    public static let defaultLimit = 6
    public static let defaultDeadline: Duration = .seconds(8)

    public init(term: String, limit: Int = VariantRequest.defaultLimit, deadline: Duration? = nil) {
        self.term = term; self.limit = limit; self.deadline = deadline
    }

    public func validate() throws {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty,
              VocabularyLimits.request.admits([term]), (1...64).contains(limit) else {
            throw CleanupError.invalidRequest("variant term must be a single nonempty line within the vocabulary term limit, and limit 1...64")
        }
        if let deadline, deadline <= .zero || deadline > .seconds(60) {
            throw CleanupError.invalidRequest("deadline must be greater than zero and at most 60 seconds")
        }
    }

    public var budget: Duration { deadline ?? Self.defaultDeadline }
}

/// A runtime that can also run its pack's variant prompt on the resident model, one
/// candidate per output line. Optional: the frozen-baseline runtime does not conform,
/// and `suggestVariants` returns `[]` without touching it.
public protocol AuxiliaryGenerating: CleanupRuntime {
    func generateVariants(_ request: VariantRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput
}

/// The app's `parseVariantLines` (pomvox/pomvox `VariantGenerator.swift`): strip a list
/// marker, lowercase, drop echoes of the term, blanks and lines over five words, dedupe, cap.
public enum VariantParser {
    public static func parse(_ raw: String, term: String, limit: Int = VariantRequest.defaultLimit) -> [String] {
        var out: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let t = stripListPrefix(line).trimmingCharacters(in: .whitespaces).lowercased()
            guard !t.isEmpty,
                  t.caseInsensitiveCompare(term) != .orderedSame,
                  t.components(separatedBy: " ").count <= 5,
                  !out.contains(t) else { continue }
            out.append(t)
            if out.count == limit { break }
        }
        return out
    }

    /// Drop a leading list marker, and nothing else. Bullets (`-`, `*`, `•`) and
    /// numbering (`2.` / `1)`) are markers; a digit that is part of the variant
    /// ("3 d printing", "3d printing") is not (pomvox/pomvox#168).
    public static func stripListPrefix(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        let bullets: Set<Character> = ["-", "*", "•"]
        if let first = t.first, bullets.contains(first) {
            while let c = t.first, bullets.contains(c) { t.removeFirst() }
            while t.first == " " { t.removeFirst() }
        }
        var index = t.startIndex
        var sawDigit = false
        while index < t.endIndex, t[index].isNumber {
            sawDigit = true
            t.formIndex(after: &index)
        }
        if sawDigit, index < t.endIndex, t[index] == "." || t[index] == ")" {
            t.formIndex(after: &index)
            while index < t.endIndex, t[index] == " " { t.formIndex(after: &index) }
            return String(t[index...])
        }
        return t
    }
}
