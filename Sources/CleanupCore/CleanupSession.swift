import Foundation
import CryptoKit

public struct RuntimeOutput: Sendable {
    public let candidate: String?
    public let failure: FallbackReason?
    public var timings: CleanupTimings
    public let warnings: [String]
    public init(candidate: String?, failure: FallbackReason? = nil,
                timings: CleanupTimings = .init(), warnings: [String] = []) {
        self.candidate = candidate; self.failure = failure
        self.timings = timings; self.warnings = warnings
    }
}

/// Implementations must retain resources until generate returns, even after cancellation.
public protocol CleanupRuntime: Sendable {
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput
    func close() async
}

/// A bounded worker independent of its waiters. Actor reentrancy cannot admit a second worker.
public enum CleanerAvailability: String, Sendable { case ready, working, quarantined, closed }

public actor CleanupSession: Cleaning {
    public var availability: CleanerAvailability {
        if closed { return .closed }
        guard let active else { return .ready }
        return entries[active] == nil ? .quarantined : .working
    }
    /// Work the one worker runs: a cleanup, or auxiliary generation on the same model.
    private enum Job: Sendable {
        case clean(CleanupRequest), variants(VariantRequest)
        var budget: Duration {
            switch self { case .clean(let r): r.budget; case .variants(let r): r.budget }
        }
    }
    private enum Outcome: Sendable { case clean(CleanupResult), variants([String]) }
    private struct Entry {
        let job: Job
        let entered: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Outcome, any Error>
        var timer: Task<Void, Never>?
        var started: ContinuousClock.Instant?
    }
    private let runtime: any CleanupRuntime
    public let provenance: Provenance
    public nonisolated var packIdentity: PackIdentity? {
        PackIdentity(id: provenance.packID, version: provenance.packVersion, digest: provenance.artifactDigest)
    }
    private let preparationMS: Double
    private let queueCapacity: Int
    private var entries: [UUID: Entry] = [:]
    private var queue: [UUID] = []
    private var active: UUID?
    private var worker: Task<Void, Never>?
    private var closed = false
    public private(set) var resourcesReleased = false

    public init(runtime: any CleanupRuntime, provenance: Provenance, preparationMS: Double = 0,
                queueCapacity: Int = 2) throws {
        guard (0...16).contains(queueCapacity), preparationMS.isFinite, preparationMS >= 0 else {
            throw CleanupError.invalidRequest("queue capacity must be 0...16 and preparation time must be finite and nonnegative")
        }
        self.runtime = runtime; self.provenance = provenance
        self.preparationMS = preparationMS; self.queueCapacity = queueCapacity
    }

    public func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        let entered = ContinuousClock.now
        try Task.checkCancellation()
        try request.validate()
        guard case .clean(let result) = try await submit(.clean(request), entered: entered) else {
            throw CleanupError.unavailable("worker returned the wrong kind of result")
        }
        try Task.checkCancellation()
        return result
    }

    /// Variant spellings for a term through the same worker as `clean`, so at most
    /// one generation runs. It never waits: anything but an idle worker, and any
    /// failure, cancellation or unsupported runtime, is `[]`. A cleanup that arrives
    /// while variants run queues behind them for at most the variant deadline.
    public func suggestVariants(_ request: VariantRequest) async -> [String] {
        guard (try? request.validate()) != nil, runtime is any AuxiliaryGenerating else { return [] }
        guard case .variants(let variants)? = try? await submit(.variants(request), entered: .now) else { return [] }
        return variants
    }

    private func submit(_ job: Job, entered: ContinuousClock.Instant) async throws -> Outcome {
        let id = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let entry = Entry(job: job, entered: entered,
                                  deadline: entered.advanced(by: job.budget), continuation: continuation)
                guard !closed else {
                    continuation.resume(returning: fallback(entry, .unavailable)); return
                }
                if case .clean(let request) = job, request.text.isEmpty {
                    continuation.resume(returning: .clean(CleanupResult(text: "", edits: [], status: .unchanged,
                        provenance: provenanceFor(request), timings: timing(entry)))); return
                }
                // An expired active worker is quarantined; never replace it while it still runs.
                guard active == nil || entries[active!] != nil else {
                    continuation.resume(returning: fallback(entry, .unavailable)); return
                }
                // Variants never take a queue slot: they must not put a dictation behind them.
                if case .variants = job, active != nil { continuation.resume(returning: fallback(entry, .busy)); return }
                guard active == nil || queue.count < queueCapacity else {
                    continuation.resume(returning: fallback(entry, .busy)); return
                }
                entries[id] = entry
                entries[id]?.timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: entry.deadline) }
                    catch { return }
                    await self?.expire(id, cancelled: false)
                }
                queue.append(id)
                startNext()
            }
        } onCancel: {
            Task { await self.expire(id, cancelled: true) }
        }
        try Task.checkCancellation()
        return result
    }

    private func startNext() {
        guard active == nil, !closed else { return }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard var entry = entries[id] else { continue }
            if ContinuousClock.now >= entry.deadline {
                finish(id, .success(fallback(entry, .timedOut))); continue
            }
            entry.started = .now
            entries[id] = entry
            active = id
            let runtime = self.runtime
            worker = Task.detached { [self] in
                let result: Result<RuntimeOutput, any Error>
                do { result = .success(try await Self.run(entry.job, on: runtime, deadline: entry.deadline)) }
                catch { result = .failure(error) }
                await workerFinished(id, output: result)
            }
            return
        }
    }

    private static func run(_ job: Job, on runtime: any CleanupRuntime,
                            deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        switch job {
        case .clean(let request): return try await runtime.generate(request, deadline: deadline)
        case .variants(let request):
            guard let auxiliary = runtime as? any AuxiliaryGenerating else {
                throw CleanupError.unavailable("this runtime has no auxiliary generation")
            }
            return try await auxiliary.generateVariants(request, deadline: deadline)
        }
    }

    private func workerFinished(_ id: UUID, output: Result<RuntimeOutput, any Error>) async {
        guard active == id else { return }
        if let entry = entries[id] {
            let result: Outcome
            if ContinuousClock.now >= entry.deadline {
                result = fallback(entry, .timedOut)
            } else {
                switch output {
                case .failure: result = fallback(entry, .unavailable)
                case .success(let output):
                    result = accepted(entry, output)
                }
            }
            finish(id, .success(result))
        }
        // GPU work has returned. Only now may another generation or resource release begin.
        active = nil
        worker = nil
        if closed { await runtime.close(); resourcesReleased = true }
        else { startNext() }
    }

    private func accepted(_ entry: Entry, _ output: RuntimeOutput) -> Outcome {
        guard case .clean(let request) = entry.job else {
            // Variants have no guard set: an unusable or late output is simply no suggestion.
            guard case .variants(let variantRequest) = entry.job, output.timings.isValid, output.failure == nil,
                  let candidate = output.candidate, candidate.utf8.count <= 65_536,
                  ContinuousClock.now < entry.deadline else { return .variants([]) }
            return .variants(VariantParser.parse(candidate, term: variantRequest.term, limit: variantRequest.limit))
        }
        return .clean(accepted(entry, request, output))
    }

    private func accepted(_ entry: Entry, _ request: CleanupRequest, _ output: RuntimeOutput) -> CleanupResult {
        guard output.timings.isValid else { return fallback(entry, request, .invalidResponse) }
        var timings = output.timings
        let base = timing(entry)
        timings.preparationMS = base.preparationMS
        timings.queueMS = base.queueMS
        timings.totalMS = base.totalMS
        timings.budgetMS = base.budgetMS
        func failed(_ reason: FallbackReason, warning: String? = nil) -> CleanupResult {
            timings.totalMS = entry.entered.duration(to: .now).milliseconds
            return CleanupResult(text: request.text, edits: [], status: .fallback(reason),
                provenance: provenanceFor(request), timings: timings,
                warnings: output.warnings + (warning.map { [$0] } ?? []))
        }
        if let reason = output.failure { return failed(reason) }
        let validationStart = ContinuousClock.now
        guard let candidate = output.candidate, candidate.utf8.count <= 65_536 else {
            return failed(.rejected, warning: "rejectedBy:invalidCandidate")
        }
        let evaluation = CleanupLogic.evaluateOutput(raw: request.text, cleaned: candidate)
        timings.validationMS = validationStart.duration(to: .now).milliseconds
        let text: String
        switch evaluation {
        case .success(let accepted): text = request.transforms.apply(to: accepted)
        case .failure(let reason): return failed(.rejected, warning: "rejectedBy:" + reason.rawValue)
        }
        let diffStart = ContinuousClock.now
        let edits = TextEdit.between(request.text, and: text)
        timings.diffMS = diffStart.duration(to: .now).milliseconds
        timings.totalMS = entry.entered.duration(to: .now).milliseconds
        if ContinuousClock.now >= entry.deadline { return failed(.timedOut) }
        return CleanupResult(text: text, edits: edits, status: edits.isEmpty ? .unchanged : .cleaned,
                             provenance: provenanceFor(request).recording(request.transforms),
                             timings: timings, warnings: output.warnings)
    }

    private func provenanceFor(_ request: CleanupRequest) -> Provenance {
        var settings = provenance.settings
        // JSON preserves term order and boundaries; no ambiguous separator concatenation.
        let data = (try? JSONEncoder().encode(request.vocabulary)) ?? Data()
        settings["vocabularySHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Provenance(packID: provenance.packID, packVersion: provenance.packVersion,
            artifactDigest: provenance.artifactDigest, modelRevision: provenance.modelRevision,
            runtime: provenance.runtime, route: provenance.route, settings: settings)
    }

    private func timing(_ entry: Entry) -> CleanupTimings {
        var value = CleanupTimings()
        value.preparationMS = preparationMS
        value.queueMS = entry.entered.duration(to: entry.started ?? .now).milliseconds
        value.totalMS = entry.entered.duration(to: .now).milliseconds
        value.budgetMS = entry.job.budget.milliseconds
        return value
    }

    private func fallback(_ entry: Entry, _ reason: FallbackReason) -> Outcome {
        switch entry.job {
        case .clean(let request): .clean(fallback(entry, request, reason))
        case .variants: .variants([])
        }
    }

    private func fallback(_ entry: Entry, _ request: CleanupRequest, _ reason: FallbackReason) -> CleanupResult {
        CleanupResult(text: request.text, edits: [], status: .fallback(reason),
                      provenance: provenanceFor(request), timings: timing(entry))
    }

    private func finish(_ id: UUID, _ result: Result<Outcome, any Error>) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        queue.removeAll { $0 == id }
        entry.continuation.resume(with: result)
    }

    private func expire(_ id: UUID, cancelled: Bool) {
        guard let entry = entries[id] else { return }
        finish(id, cancelled ? .failure(CancellationError()) : .success(fallback(entry, .timedOut)))
        if active == id {
            worker?.cancel()
            // Fail pending waiters rather than growing a queue behind an unresponsive device.
            for queuedID in queue {
                if let pending = entries[queuedID] { finish(queuedID, .success(fallback(pending, .unavailable))) }
            }
        }
    }

    /// Stops admission immediately. Resource release waits for any active worker to return.
    public func close() async {
        guard !closed else { return }
        closed = true
        worker?.cancel()
        for (id, entry) in entries { finish(id, .success(fallback(entry, .unavailable))) }
        if active == nil { await runtime.close(); resourcesReleased = true }
    }
}
