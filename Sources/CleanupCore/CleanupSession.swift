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
public actor CleanupSession: Cleaning {
    private struct Entry {
        let request: CleanupRequest
        let entered: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<CleanupResult, any Error>
        var timer: Task<Void, Never>?
        var started: ContinuousClock.Instant?
    }
    private let runtime: any CleanupRuntime
    public let provenance: Provenance
    private let preparationMS: Double
    private let queueCapacity: Int
    private var entries: [UUID: Entry] = [:]
    private var queue: [UUID] = []
    private var active: UUID?
    private var worker: Task<Void, Never>?
    private var closed = false

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
        let id = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let entry = Entry(request: request, entered: entered,
                                  deadline: entered.advanced(by: request.budget), continuation: continuation)
                guard !closed else {
                    continuation.resume(returning: fallback(entry, .unavailable)); return
                }
                if request.text.isEmpty {
                    continuation.resume(returning: CleanupResult(text: "", edits: [], status: .unchanged,
                        provenance: provenanceFor(entry), timings: timing(entry))); return
                }
                // An expired active worker is quarantined; never replace it while it still runs.
                guard active == nil || entries[active!] != nil else {
                    continuation.resume(returning: fallback(entry, .unavailable)); return
                }
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
                do { result = .success(try await runtime.generate(entry.request, deadline: entry.deadline)) }
                catch { result = .failure(error) }
                await workerFinished(id, output: result)
            }
            return
        }
    }

    private func workerFinished(_ id: UUID, output: Result<RuntimeOutput, any Error>) async {
        guard active == id else { return }
        if let entry = entries[id] {
            let result: CleanupResult
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
        if closed { await runtime.close() }
        else { startNext() }
    }

    private func accepted(_ entry: Entry, _ output: RuntimeOutput) -> CleanupResult {
        if let reason = output.failure { return fallback(entry, reason) }
        guard output.timings.isValid else { return fallback(entry, .invalidResponse) }
        let validationStart = ContinuousClock.now
        guard let candidate = output.candidate, candidate.utf8.count <= 65_536,
              let text = CleanupLogic.acceptOutput(raw: entry.request.text, cleaned: candidate)
        else { return fallback(entry, .rejected) }
        var timings = timing(entry)
        timings.tokenizationMS = output.timings.tokenizationMS
        timings.prefillMS = output.timings.prefillMS
        timings.inferenceMS = output.timings.inferenceMS
        timings.validationMS = validationStart.duration(to: .now).milliseconds
        let diffStart = ContinuousClock.now
        let edits = TextEdit.between(entry.request.text, and: text)
        timings.diffMS = diffStart.duration(to: .now).milliseconds
        timings.totalMS = entry.entered.duration(to: .now).milliseconds
        if ContinuousClock.now >= entry.deadline { return fallback(entry, .timedOut) }
        return CleanupResult(text: text, edits: edits, status: edits.isEmpty ? .unchanged : .cleaned,
                             provenance: provenanceFor(entry), timings: timings, warnings: output.warnings)
    }

    private func provenanceFor(_ entry: Entry) -> Provenance {
        var settings = provenance.settings
        // JSON preserves term order and boundaries; no ambiguous separator concatenation.
        let data = (try? JSONEncoder().encode(entry.request.vocabulary)) ?? Data()
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
        value.budgetMS = entry.request.budget.milliseconds
        return value
    }

    private func fallback(_ entry: Entry, _ reason: FallbackReason) -> CleanupResult {
        CleanupResult(text: entry.request.text, edits: [], status: .fallback(reason),
                      provenance: provenanceFor(entry), timings: timing(entry))
    }

    private func finish(_ id: UUID, _ result: Result<CleanupResult, any Error>) {
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
        if active == nil { await runtime.close() }
    }
}
