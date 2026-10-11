@_exported import CleanupDiarization
import CoreML
import FluidAudio
import Foundation

/// Knobs the host may set once per open. Everything else is the pyannote
/// community-1 default the Core ML export was made for.
public struct FluidDiarizerConfig: Sendable {
    /// Core ML compute units for the segmentation, embedding and PLDA models
    /// (the FBank front end always runs on the CPU, as the exporter requires).
    public var computeUnits: MLComputeUnits
    /// Clustering threshold; the community-1 default is 0.6. Lower finds more speakers.
    public var clusteringThreshold: Double

    public init(computeUnits: MLComputeUnits = .all, clusteringThreshold: Double = 0.6) {
        self.computeUnits = computeUnits; self.clusteringThreshold = clusteringThreshold
    }
}

/// Core ML model objects are not `Sendable`; they are written once at open and read afterwards.
private final class Box<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Local diarizer over FluidAudio's offline pipeline (pyannote community-1
/// segmentation, WeSpeaker embeddings, VBx clustering on the Neural Engine).
///
/// One request at a time, no queue: diarization is batch work over a whole
/// recording. A request's deadline is enforced by this actor, not by the
/// pipeline: a late worker's result is discarded, new requests are refused
/// (`busy`) until it returns, and models stay alive until then.
///
/// `open` turns on `ModelHub.offlineMode`, which is process-global in
/// FluidAudio: after it every FluidAudio loader in the process refuses to
/// download and throws instead. That is the local-first guarantee this SDK
/// makes, and a host using FluidAudio for its own STT must stage those models
/// too (the Pomvox app already does).
public actor FluidDiarizer: Diarizing {
    public static let runtimeName = "fluidaudio-0.15.5/pyannote-community-1-offline"

    nonisolated public let pack: ValidatedDiarizerPack
    nonisolated public let config: FluidDiarizerConfig
    /// Model load and compile time, separate from any request.
    nonisolated public let preparationMS: Double

    private var models: Box<OfflineDiarizerModels>?
    private struct Pending {
        let continuation: CheckedContinuation<SpeakerSegmentation, any Error>
        let timer: Task<Void, Never>
    }
    private var pending: Pending?
    private var worker: Task<Void, Never>?
    private var closed = false

    private init(pack: ValidatedDiarizerPack, config: FluidDiarizerConfig,
                 models: OfflineDiarizerModels, preparationMS: Double) {
        self.pack = pack; self.config = config; self.models = Box(models); self.preparationMS = preparationMS
    }

    /// Revalidates the pack's file identity, forbids downloads for the process,
    /// and loads the four Core ML bundles from the pack. Never touches the network.
    public static func open(pack: ValidatedDiarizerPack,
                            config: FluidDiarizerConfig = FluidDiarizerConfig()) async throws -> FluidDiarizer {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        let pack = try DiarizerPackLoader.revalidate(pack)
        guard config.clusteringThreshold.isFinite, (0.0...1.0).contains(config.clusteringThreshold) else {
            throw DiarizationError.invalidRequest("clustering threshold must be within 0...1")
        }
        ModelHub.offlineMode = true
        let configuration = MLModelConfiguration()
        configuration.computeUnits = config.computeUnits
        let models: OfflineDiarizerModels
        do {
            models = try await OfflineDiarizerModels.load(from: pack.modelsDirectory, configuration: configuration)
        } catch {
            throw DiarizationError.unavailable("could not load diarizer models: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        return FluidDiarizer(pack: pack, config: config, models: models,
                             preparationMS: start.duration(to: .now).milliseconds)
    }

    /// A snapshot, not a reservation.
    public var availability: CleanerAvailability {
        if closed { return .closed }
        guard worker != nil else { return .ready }
        return pending == nil ? .quarantined : .working
    }

    public func diarize(_ request: DiarizationRequest) async throws -> SpeakerSegmentation {
        let entered = ContinuousClock.now
        try Task.checkCancellation()
        try request.validate()
        guard !closed, let models else { throw DiarizationError.unavailable("diarizer is closed") }
        guard worker == nil else { throw DiarizationError.busy }
        let deadline = entered.advanced(by: request.budget)
        var offline = OfflineDiarizerConfig.default
        offline.clustering.threshold = config.clusteringThreshold
        if let speakers = request.speakers {
            if speakers.lowerBound == speakers.upperBound {
                offline.clustering.numSpeakers = speakers.lowerBound
            } else {
                offline.clustering.minSpeakers = speakers.lowerBound
                offline.clustering.maxSpeakers = speakers.upperBound
            }
        }
        let manager = OfflineDiarizerManager(config: offline)
        manager.initialize(models: models.value)
        let boxed = Box(manager)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeakerSegmentation, any Error>) in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.expire(cancelled: false)
                }
                pending = Pending(continuation: continuation, timer: timer)
                worker = Task.detached { [self] in
                    let outcome: Result<DiarizationResult, any Error>
                    do {
                        switch request.audio {
                        case .samples16kMono(let samples): outcome = .success(try await boxed.value.process(audio: samples))
                        case .file(let url): outcome = .success(try await boxed.value.process(url))
                        }
                    } catch { outcome = .failure(error) }
                    await self.finished(outcome, request: request, entered: entered)
                }
            }
        } onCancel: {
            Task { await self.expire(cancelled: true) }
        }
        try Task.checkCancellation()
        return result
    }

    private func finished(_ outcome: Result<DiarizationResult, any Error>,
                          request: DiarizationRequest, entered: ContinuousClock.Instant) {
        defer {
            worker = nil
            if closed { models = nil }
        }
        guard let pending else { return } // expired or canceled: late output is discarded
        self.pending = nil
        pending.timer.cancel()
        if ContinuousClock.now >= entered.advanced(by: request.budget) {
            pending.continuation.resume(throwing: DiarizationError.timedOut); return
        }
        switch outcome {
        case .failure(let error):
            if case OfflineDiarizationError.noSpeechDetected = error {
                pending.continuation.resume(throwing: DiarizationError.noSpeech)
            } else {
                pending.continuation.resume(throwing: DiarizationError.failed(error.localizedDescription))
            }
        case .success(let raw):
            let segmentation = map(raw, request: request, entered: entered)
            guard segmentation.isValid else {
                pending.continuation.resume(throwing: DiarizationError.failed("pipeline returned an invalid segmentation")); return
            }
            pending.continuation.resume(returning: segmentation)
        }
    }

    private func map(_ raw: DiarizationResult, request: DiarizationRequest,
                     entered: ContinuousClock.Instant) -> SpeakerSegmentation {
        let segments = raw.segments.compactMap { segment -> SpeakerSegment? in
            let span = TimeSpan(start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds))
            guard span.isValid, span.duration > 0 else { return nil }
            let quality = Double(segment.qualityScore)
            return SpeakerSegment(speaker: SpeakerLabel(segment.speakerId), span: span,
                                  confidence: quality.isFinite ? min(1, max(0, quality)) : nil)
        }
        var timings = DiarizationTimings()
        timings.audioSeconds = request.audioSeconds ?? segments.map(\.span.end).max()
        if let pipeline = raw.timings {
            timings.audioLoadMS = pipeline.audioLoadingSeconds * 1_000
            timings.segmentationMS = pipeline.segmentationSeconds * 1_000
            timings.embeddingMS = pipeline.embeddingExtractionSeconds * 1_000
            timings.clusteringMS = pipeline.speakerClusteringSeconds * 1_000
        }
        timings.totalMS = entered.duration(to: .now).milliseconds
        timings.budgetMS = request.budget.milliseconds
        var settings = ["pipeline": DiarizerPackLoader.pipeline,
                        "clusteringThreshold": String(config.clusteringThreshold),
                        "computeUnits": String(config.computeUnits.rawValue)]
        if let speakers = request.speakers { settings["speakers"] = "\(speakers.lowerBound)...\(speakers.upperBound)" }
        let provenance = Provenance(packID: pack.manifest.id, packVersion: pack.manifest.version,
            artifactDigest: pack.digest, modelRevision: pack.manifest.modelRevision,
            runtime: Self.runtimeName, route: "local", settings: settings)
        let dropped = raw.segments.count - segments.count
        return SpeakerSegmentation(segments: segments, speakerCount: Set(segments.map(\.speaker)).count,
            provenance: provenance, timings: timings,
            warnings: dropped > 0 ? ["dropped-\(dropped)-degenerate-segments"] : []).relabeled()
    }

    private func expire(cancelled: Bool) {
        guard let pending else { return }
        self.pending = nil
        pending.timer.cancel()
        // The pipeline has no cancellation point; the worker runs to completion and is discarded.
        pending.continuation.resume(throwing: cancelled ? CancellationError() : DiarizationError.timedOut)
    }

    /// Stops admission immediately. Models are released when no worker is running,
    /// otherwise when the running worker returns.
    public func close() {
        guard !closed else { return }
        closed = true
        if let pending {
            self.pending = nil
            pending.timer.cancel()
            pending.continuation.resume(throwing: DiarizationError.unavailable("diarizer is closed"))
        }
        if worker == nil { models = nil }
    }
}
