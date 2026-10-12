@_exported import CleanupNotes
import Foundation

/// Notes wire protocol version 1: one cleaned transcript turn.
public struct CloudTurn: Codable, Sendable {
    public let index: Int
    public let speaker: SpeakerLabel?
    public let text: String
    public let start: TimeInterval?
    public let end: TimeInterval?
}

public struct CloudNotesRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let pack: RemotePack
    public let turns: [CloudTurn]
    public let style: String?
    public let remainingMilliseconds: Int
}

public struct CloudNotesResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let result: ModelNotes
}

public struct NotesWriteOptions: Sendable {
    /// A short style hint the endpoint may honor ("meeting", "standup"); at most 64 bytes, one line.
    public var style: String?
    public var deadline: Duration?
    public static let maxStyleBytes = 64
    public static let maxDeadline: Duration = .seconds(600)

    public init(style: String? = nil, deadline: Duration? = nil) { self.style = style; self.deadline = deadline }

    public var budget: Duration { deadline ?? .seconds(60) }

    func validate() throws {
        if let style, style.isEmpty || style.utf8.count > Self.maxStyleBytes || style.contains(where: \.isNewline) {
            throw ModelNotesError.invalidRequest("style must be one line of at most \(Self.maxStyleBytes) bytes")
        }
        if let deadline, deadline <= .zero || deadline > Self.maxDeadline {
            throw ModelNotesError.invalidRequest("deadline must be greater than zero and at most ten minutes")
        }
    }
}

/// Explicit cloud note writer, with `CloudCleaner`'s posture. `write` sends the
/// cleaned transcript to the configured endpoint and returns the model's notes
/// only after every note's citations have been checked against that
/// transcript. On any failure it throws; the host keeps the deterministic
/// `Notes` it already has, which never depended on this call.
public actor CloudNotes {
    /// Longest transcript per request, in UTF-8 bytes of turn text.
    public static let maxTranscriptBytes = 524_288
    static let maxResponseBytes = 1_048_576

    private struct Pending {
        let id: UUID
        let entered: ContinuousClock.Instant
        let budget: Duration
        let continuation: CheckedContinuation<ModelNotes, any Error>
        let timer: Task<Void, Never>
    }
    private let endpoint: URL
    private let credentials: any CredentialProvider
    private let pack: RemotePack
    private let session: URLSession
    private var worker: Task<Void, Never>?
    private var pending: Pending?
    private var closed = false

    private init(endpoint: URL, credentials: any CredentialProvider, pack: RemotePack) {
        self.endpoint = endpoint; self.credentials = credentials; self.pack = pack
        session = CloudTransport.makeSession()
    }

    /// Validates configuration only; no request or credential retrieval until `write`.
    public static func connect(endpoint: URL, credentials: any CredentialProvider, pack: RemotePack) throws -> CloudNotes {
        try CloudTransport.validate(endpoint: endpoint, pack: pack)
        return CloudNotes(endpoint: endpoint, credentials: credentials, pack: pack)
    }

    /// A snapshot, not a reservation.
    public var availability: CleanerAvailability {
        if closed { return .closed }
        guard worker != nil else { return .ready }
        return pending == nil ? .quarantined : .working
    }

    public func write(for source: TranscriptResult,
                      options: NotesWriteOptions = NotesWriteOptions()) async throws -> ModelNotes {
        let entered = ContinuousClock.now
        try Task.checkCancellation()
        try options.validate()
        guard !source.turns.isEmpty else { throw ModelNotesError.invalidRequest("transcript has no turns") }
        guard source.turns.count <= Transcript.maxTurns else {
            throw ModelNotesError.invalidRequest("transcript exceeds \(Transcript.maxTurns) turns")
        }
        guard source.turns.reduce(0, { $0 + $1.text.utf8.count }) <= Self.maxTranscriptBytes else {
            throw ModelNotesError.invalidRequest("transcript exceeds \(Self.maxTranscriptBytes) bytes for one request")
        }
        guard !closed else { throw ModelNotesError.unavailable("notes client is closed") }
        guard worker == nil else { throw ModelNotesError.busy }
        let budget = options.budget
        let deadline = entered.advanced(by: budget)
        let id = UUID()
        let turns = source.turns.enumerated().map { index, turn in
            CloudTurn(index: index, speaker: turn.turn.speaker, text: turn.text, start: turn.turn.span?.start, end: turn.turn.span?.end)
        }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ModelNotes, any Error>) in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.expire(id: id, cancelled: false)
                }
                pending = Pending(id: id, entered: entered, budget: budget, continuation: continuation, timer: timer)
                let session = self.session, endpoint = self.endpoint, credentials = self.credentials, pack = self.pack
                worker = Task.detached { [self] in
                    let outcome: Result<ModelNotes, any Error>
                    do {
                        outcome = .success(try await Self.send(turns, style: options.style, source: source, id: id,
                            deadline: deadline, session: session, endpoint: endpoint, credentials: credentials, pack: pack))
                    } catch { outcome = .failure(error) }
                    await completed(outcome)
                }
            }
        } onCancel: { Task { await self.expire(id: id, cancelled: true) } }
        try Task.checkCancellation()
        return result
    }

    private static func send(_ turns: [CloudTurn], style: String?, source: TranscriptResult, id: UUID,
                             deadline: ContinuousClock.Instant, session: URLSession, endpoint: URL,
                             credentials: any CredentialProvider, pack: RemotePack) async throws -> ModelNotes {
        let token = try await credentials.bearerToken()
        try Task.checkCancellation()
        guard CloudTransport.isValidBearer(token) else { throw ModelNotesError.unavailable("invalid bearer credential") }
        let remaining = ContinuousClock.now.duration(to: deadline).milliseconds
        guard remaining > 0 else { throw URLError(.timedOut) }
        let payload = CloudNotesRequest(schemaVersion: 1, requestID: id, pack: pack, turns: turns, style: style,
                                        remainingMilliseconds: max(1, Int(remaining)))
        var request = URLRequest(url: endpoint, timeoutInterval: remaining / 1_000)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(payload)
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "application/json" else { throw URLError(.badServerResponse) }
        var body = Data()
        for try await byte in stream {
            guard body.count < maxResponseBytes else { throw ModelNotesError.invalidResponse("oversized response") }
            body.append(byte)
        }
        let decoded: CloudNotesResponse
        do { decoded = try JSONDecoder().decode(CloudNotesResponse.self, from: body) }
        catch { throw ModelNotesError.invalidResponse("undecodable response") }
        return try validated(decoded, id: id, pack: pack, source: source)
    }

    /// Everything the client checks before model notes reach the host.
    static func validated(_ response: CloudNotesResponse, id: UUID, pack: RemotePack,
                          source: TranscriptResult) throws -> ModelNotes {
        guard response.schemaVersion == 1 else { throw ModelNotesError.invalidResponse("schema") }
        guard response.requestID == id else { throw ModelNotesError.invalidResponse("request id") }
        let result = response.result
        guard result.provenance.packID == pack.id, result.provenance.packVersion == pack.version else {
            throw ModelNotesError.invalidResponse("pack")
        }
        guard result.provenance.route == "cloud", !result.provenance.runtime.isEmpty,
              !result.provenance.artifactDigest.isEmpty, !result.provenance.modelRevision.isEmpty else {
            throw ModelNotesError.invalidResponse("provenance")
        }
        try result.validate(against: source)
        return result
    }

    private func completed(_ outcome: Result<ModelNotes, any Error>) {
        defer {
            worker = nil
            // The session may be invalidated only after the worker that used it has returned.
            if closed { session.invalidateAndCancel() }
        }
        guard let pending else { return } // expired, canceled or closed: late output is discarded
        self.pending = nil
        pending.timer.cancel()
        let elapsed = pending.entered.duration(to: .now)
        if elapsed >= pending.budget { pending.continuation.resume(throwing: ModelNotesError.timedOut); return }
        switch outcome {
        case .success(var notes):
            notes.timings.serverInferenceMS = notes.timings.inferenceMS
            notes.timings.totalMS = elapsed.milliseconds
            notes.timings.budgetMS = pending.budget.milliseconds
            pending.continuation.resume(returning: notes)
        case .failure(let error):
            let mapped: any Error
            if let url = error as? URLError {
                mapped = url.code == .timedOut ? ModelNotesError.timedOut : ModelNotesError.transport(url.localizedDescription)
            } else if error is ModelNotesError || error is CancellationError {
                mapped = error
            } else {
                mapped = ModelNotesError.transport(String(describing: error))
            }
            pending.continuation.resume(throwing: mapped)
        }
    }

    private func expire(id: UUID, cancelled: Bool) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.timer.cancel()
        worker?.cancel()
        pending.continuation.resume(throwing: cancelled ? CancellationError() : ModelNotesError.timedOut)
    }

    /// Stops admission immediately, fails a waiting request and cancels delivery.
    /// The transport session is released when no worker can still touch it.
    public func close() {
        guard !closed else { return }
        closed = true
        if let pending {
            self.pending = nil
            pending.timer.cancel()
            pending.continuation.resume(throwing: ModelNotesError.unavailable("notes client is closed"))
        }
        worker?.cancel()
        if worker == nil { session.invalidateAndCancel() }
    }

    deinit { session.invalidateAndCancel() }
}
