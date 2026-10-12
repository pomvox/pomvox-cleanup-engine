@_exported import CleanupCore
import Foundation

/// Audio a host hands to a diarizer. The SDK owns no microphone: the host
/// captured this, and decides whether it may be processed.
public enum DiarizationAudio: Sendable {
    /// Mono Float32 samples at `DiarizationRequest.sampleRate`.
    case samples16kMono([Float])
    /// A local audio file; the runtime decodes and resamples it.
    case file(URL)
}

public enum DiarizationError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String)
    case unavailable(String)
    /// A request is already running. There is no queue: diarization is batch work.
    case busy
    /// The deadline passed. The worker's late result is discarded.
    case timedOut
    case noSpeech
    case failed(String)
    /// A cloud client could not reach or complete the exchange with its endpoint.
    case transport(String)
    /// A cloud endpoint answered with something the client refused to hand on.
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): "Invalid diarization request: \(detail)"
        case .unavailable(let detail): "Diarization is unavailable: \(detail)"
        case .busy: "Diarization is busy with another request."
        case .timedOut: "Diarization did not finish before its deadline."
        case .noSpeech: "No speech was detected in the audio."
        case .failed(let detail): "Diarization failed: \(detail)"
        case .transport(let detail): "Diarization transport failed: \(detail)"
        case .invalidResponse(let detail): "Diarization endpoint returned an invalid response: \(detail)"
        }
    }
}

public struct DiarizationRequest: Sendable {
    public let audio: DiarizationAudio
    /// Expected number of speakers, as bounds. Nil: let the model decide.
    /// A single-value range pins the count.
    public let speakers: ClosedRange<Int>?
    public let deadline: Duration?

    public static let sampleRate = 16_000
    /// Longest admitted audio, in seconds (two hours).
    public static let maxSeconds: TimeInterval = 7_200
    public static let maxDeadline: Duration = .seconds(3_600)
    public static let maxSpeakers = 50

    public init(audio: DiarizationAudio, speakers: ClosedRange<Int>? = nil, deadline: Duration? = nil) {
        self.audio = audio; self.speakers = speakers; self.deadline = deadline
    }

    public init(samples: [Float], speakers: ClosedRange<Int>? = nil, deadline: Duration? = nil) {
        self.init(audio: .samples16kMono(samples), speakers: speakers, deadline: deadline)
    }

    /// Seconds of audio when known before decoding; nil for a file.
    public var audioSeconds: TimeInterval? {
        if case .samples16kMono(let samples) = audio { return Double(samples.count) / Double(Self.sampleRate) }
        return nil
    }

    public func validate() throws {
        switch audio {
        case .samples16kMono(let samples):
            guard !samples.isEmpty else { throw DiarizationError.invalidRequest("audio is empty") }
            guard Double(samples.count) <= Self.maxSeconds * Double(Self.sampleRate) else {
                throw DiarizationError.invalidRequest("audio exceeds \(Int(Self.maxSeconds)) seconds")
            }
        case .file(let url):
            guard url.isFileURL else { throw DiarizationError.invalidRequest("audio must be a local file") }
        }
        if let speakers {
            guard speakers.lowerBound >= 1, speakers.upperBound <= Self.maxSpeakers else {
                throw DiarizationError.invalidRequest("speakers must be within 1...\(Self.maxSpeakers)")
            }
        }
        if let deadline, deadline <= .zero || deadline > Self.maxDeadline {
            throw DiarizationError.invalidRequest("deadline must be greater than zero and at most one hour")
        }
    }

    /// Explicit deadlines win. Otherwise half the audio's length, at least one
    /// minute, or ten minutes for a file of unknown length; never over an hour.
    public var budget: Duration {
        if let deadline { return deadline }
        guard let seconds = audioSeconds else { return .seconds(600) }
        return .seconds(min(3_600, max(60, 0.5 * seconds)))
    }
}

public struct DiarizationTimings: Codable, Equatable, Sendable {
    public var audioSeconds: Double? = nil
    public var audioLoadMS: Double? = nil
    public var segmentationMS: Double? = nil
    public var embeddingMS: Double? = nil
    public var clusteringMS: Double? = nil
    public var totalMS: Double = 0
    public var budgetMS: Double = 0
    public init() {}

    public var isValid: Bool {
        ([totalMS, budgetMS] + [audioSeconds, audioLoadMS, segmentationMS, embeddingMS, clusteringMS].compactMap { $0 })
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

/// Who spoke when, over one recording. Labels are opaque and local to this
/// value; `relabeled()` gives the first-appearance order a host can rely on.
public struct SpeakerSegmentation: Codable, Equatable, Sendable {
    public let segments: [SpeakerSegment]
    public let speakerCount: Int
    public let provenance: Provenance
    public var timings: DiarizationTimings
    public let warnings: [String]

    public static let maxSegments = 4_096

    public init(segments: [SpeakerSegment], speakerCount: Int, provenance: Provenance,
                timings: DiarizationTimings = .init(), warnings: [String] = []) {
        self.segments = segments; self.speakerCount = speakerCount
        self.provenance = provenance; self.timings = timings; self.warnings = warnings
    }

    /// Distinct speakers in order of first appearance.
    public var speakers: [SpeakerLabel] {
        var seen = Set<SpeakerLabel>()
        return segments.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    /// Bounded, valid spans sorted by start, a consistent speaker count, valid timings.
    public var isValid: Bool {
        segments.count <= Self.maxSegments
            && segments.allSatisfy { $0.span.isValid && ($0.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true) }
            && zip(segments, segments.dropFirst()).allSatisfy { $0.span.start <= $1.span.start }
            && speakerCount == Set(segments.map(\.speaker)).count
            && timings.isValid
    }

    /// The same segmentation with speakers renamed `S1`, `S2`, ... in order of
    /// first appearance and segments sorted by start. Runtimes return this form.
    public func relabeled() -> SpeakerSegmentation {
        let sorted = segments.enumerated()
            .sorted { ($0.element.span.start, $0.offset) < ($1.element.span.start, $1.offset) }
            .map(\.element)
        var names: [SpeakerLabel: SpeakerLabel] = [:]
        let renamed = sorted.map { segment in
            let label = names[segment.speaker] ?? SpeakerLabel("S\(names.count + 1)")
            names[segment.speaker] = label
            return SpeakerSegment(speaker: label, span: segment.span, confidence: segment.confidence)
        }
        return SpeakerSegmentation(segments: renamed, speakerCount: names.count, provenance: provenance,
                                   timings: timings, warnings: warnings)
    }
}

/// A diarizer: audio in, speaker segments out. Implementations are local
/// runtimes over verified packs or explicit cloud clients; neither is chosen
/// implicitly. Implementations must keep resources alive until a running
/// request returns, even after cancellation or a passed deadline.
public protocol Diarizing: Sendable {
    func diarize(_ request: DiarizationRequest) async throws -> SpeakerSegmentation
    /// Stops admission; may return before a running request's resources are released.
    func close() async
    /// Stops admission and returns once no request is running and resources are
    /// released. Cancelling the waiting task stops the wait and throws; it never
    /// reopens admission.
    func closeAndWait() async throws
}

extension Diarizing {
    /// For a diarizer whose `close()` already releases everything before returning.
    /// One that keeps resources alive for a running request must implement it.
    public func closeAndWait() async throws {
        await close()
        try Task.checkCancellation()
    }
}
