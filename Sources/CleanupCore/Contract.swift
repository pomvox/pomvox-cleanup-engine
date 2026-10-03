import Foundation

public enum CleanupError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String)
    case invalidPack(String)
    case incompatible(String)
    case invalidEdits
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): "Invalid cleanup request: \(detail)"
        case .invalidPack(let detail): "Invalid cleanup pack: \(detail)"
        case .incompatible(let detail): "Incompatible cleanup configuration: \(detail)"
        case .invalidEdits: "Cleanup edits do not reconstruct a valid result."
        case .unavailable(let detail): "Cleanup is unavailable: \(detail)"
        }
    }
}

public enum FallbackReason: String, Codable, Sendable {
    case timedOut, rejected, unavailable, busy, tokenLimit, transport, invalidResponse
}

public enum CleanupStatus: Codable, Equatable, Sendable {
    case cleaned, unchanged
    case fallback(FallbackReason)
}

/// Deterministic post-transforms a host opts into. Applied to accepted model
/// output only; a fallback is always the exact input with no edits.
public struct CleanupTransforms: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Spoken "new line", "new paragraph" and "bullet" become layout (`SpokenLayout`).
    public static let spokenLayout = CleanupTransforms(rawValue: 1 << 0)

    public func apply(to text: String) -> String {
        contains(.spokenLayout) ? SpokenLayout.apply(text) : text
    }
}

extension Provenance {
    /// Records applied transforms alongside the other applied settings; unchanged when none.
    public func recording(_ transforms: CleanupTransforms) -> Provenance {
        guard transforms.contains(.spokenLayout) else { return self }
        var settings = self.settings
        settings["transforms"] = "spokenLayout"
        return Provenance(packID: packID, packVersion: packVersion, artifactDigest: artifactDigest,
                          modelRevision: modelRevision, runtime: runtime, route: route, settings: settings)
    }
}

/// Vocabulary bounds. `request` is what any request may carry; a pack may declare
/// stricter limits in its capabilities, never looser ones.
public struct VocabularyLimits: Codable, Equatable, Sendable {
    public let maxTerms: Int
    public let maxTermBytes: Int
    public let maxTotalBytes: Int

    public init(maxTerms: Int, maxTermBytes: Int, maxTotalBytes: Int) {
        self.maxTerms = maxTerms; self.maxTermBytes = maxTermBytes; self.maxTotalBytes = maxTotalBytes
    }

    public static let request = VocabularyLimits(maxTerms: 64, maxTermBytes: 128, maxTotalBytes: 2_048)

    /// Nonempty single-line terms within every bound.
    public func admits(_ vocabulary: [String]) -> Bool {
        vocabulary.count <= maxTerms
            && vocabulary.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maxTermBytes && !$0.contains(where: { $0.isNewline }) })
            && vocabulary.reduce(0, { $0 + $1.utf8.count }) <= maxTotalBytes
    }
}

/// What a pack supports, so a host can avoid offering what would be refused or ignored.
/// Answered before open (`ValidatedPack.capabilities`) and after (`Cleaner.capabilities`).
public struct PackCapabilities: Codable, Equatable, Sendable {
    /// Style names a request may select. Empty: the prompt is frozen.
    public let styles: [String]
    /// Whether a host may switch speculative decoding on or off.
    public let speculativeSwitch: Bool
    /// Whether the pack offers auxiliary generation (for example dictionary variants).
    public let auxiliaryGeneration: Bool
    /// Minimum resident memory for the loaded pack, in bytes. Nil: not measured.
    public let minResidentMemoryBytes: Int?
    public let vocabulary: VocabularyLimits

    public init(styles: [String], speculativeSwitch: Bool, auxiliaryGeneration: Bool,
                minResidentMemoryBytes: Int?, vocabulary: VocabularyLimits) {
        self.styles = styles; self.speculativeSwitch = speculativeSwitch
        self.auxiliaryGeneration = auxiliaryGeneration
        self.minResidentMemoryBytes = minResidentMemoryBytes; self.vocabulary = vocabulary
    }

    /// The frozen-prompt baseline every schema-1 pack (including simplewords-v3) has.
    /// Memory is not measured yet.
    public static let frozenBaseline = PackCapabilities(
        styles: [], speculativeSwitch: false, auxiliaryGeneration: false,
        minResidentMemoryBytes: nil, vocabulary: .request)
}

public struct CleanupRequest: Sendable {
    public let text: String
    public let vocabulary: [String]
    /// Reserved for future packs. The baseline rejects nonempty context/settings.
    public let context: String
    public let settings: [String: String]
    public let deadline: Duration?
    /// Off by default. Not sent to a cloud endpoint; the client applies them.
    public let transforms: CleanupTransforms

    public init(_ text: String, vocabulary: [String] = [], context: String = "",
                settings: [String: String] = [:], deadline: Duration? = nil,
                transforms: CleanupTransforms = []) {
        self.text = text
        self.vocabulary = vocabulary
        self.context = context
        self.settings = settings
        self.deadline = deadline
        self.transforms = transforms
    }

    public func validate() throws {
        let limits = VocabularyLimits.request
        guard text.utf8.count <= 16_384, limits.admits(vocabulary),
              context.utf8.count <= 2_048, settings.count <= 16,
              settings.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 128 })
        else { throw CleanupError.invalidRequest("request exceeds documented limits") }
        if let deadline, deadline <= .zero || deadline > .seconds(60) {
            throw CleanupError.invalidRequest("deadline must be greater than zero and at most 60 seconds")
        }
    }

    /// Bounded adaptive policy; no reload credit. Explicit deadlines always win.
    public var budget: Duration {
        deadline ?? .seconds(min(60, max(5, 2 + 0.012 * Double(text.count))))
    }
}

public struct Provenance: Codable, Equatable, Sendable {
    public let packID: String
    public let packVersion: String
    public let artifactDigest: String
    public let modelRevision: String
    public let runtime: String
    public let route: String
    public let settings: [String: String]

    public init(packID: String, packVersion: String, artifactDigest: String,
                modelRevision: String, runtime: String, route: String,
                settings: [String: String] = [:]) {
        self.packID = packID; self.packVersion = packVersion
        self.artifactDigest = artifactDigest; self.modelRevision = modelRevision
        self.runtime = runtime; self.route = route; self.settings = settings
    }
}

public struct CleanupTimings: Codable, Equatable, Sendable {
    public var preparationMS: Double = 0
    public var queueMS: Double = 0
    public var tokenizationMS: Double? = nil
    public var prefillMS: Double? = nil
    public var inferenceMS: Double? = nil
    public var validationMS: Double = 0
    public var diffMS: Double = 0
    public var totalMS: Double = 0
    public var budgetMS: Double = 0
    public var prefixCacheUsed: Bool? = nil
    public var promptTokens: Int? = nil
    public var decodeTokens: Int? = nil
    public var speculativeRounds: Int? = nil
    public var speculativeDrafted: Int? = nil
    public var speculativeAccepted: Int? = nil
    public var serverInferenceMS: Double? = nil
    public init() {}

    /// Metrics crossing a runtime or transport boundary must remain JSON-encodable.
    public var isValid: Bool {
        let required = [preparationMS, queueMS, validationMS, diffMS, totalMS, budgetMS]
        let optional = [tokenizationMS, prefillMS, inferenceMS, serverInferenceMS].compactMap { $0 }
        let counts = [promptTokens, decodeTokens, speculativeRounds, speculativeDrafted, speculativeAccepted].compactMap { $0 }
        return (required + optional).allSatisfy { $0.isFinite && $0 >= 0 }
            && counts.allSatisfy { $0 >= 0 }
            && (speculativeAccepted ?? 0) <= (speculativeDrafted ?? 0)
    }
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public let text: String
    public let edits: [TextEdit]
    public let status: CleanupStatus
    public let provenance: Provenance
    public var timings: CleanupTimings
    public let warnings: [String]

    public init(text: String, edits: [TextEdit], status: CleanupStatus, provenance: Provenance,
                timings: CleanupTimings = .init(), warnings: [String] = []) {
        self.text = text; self.edits = edits; self.status = status
        self.provenance = provenance; self.timings = timings; self.warnings = warnings
    }
}

public protocol Cleaning: Sendable {
    func clean(_ request: CleanupRequest) async throws -> CleanupResult
}

extension Cleaning {
    public func clean(_ text: String) async throws -> CleanupResult {
        try await clean(CleanupRequest(text))
    }
}

extension Duration {
    public var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
