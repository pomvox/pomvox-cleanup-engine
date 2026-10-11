@_exported import CleanupDiarization
import Foundation

/// Diarization wire protocol version 1 response body.
public struct CloudDiarizationResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let result: SpeakerSegmentation
}

/// Explicit cloud diarizer, with `CloudCleaner`'s posture: an endpoint, a
/// credential provider and a remote pack are required; `connect` sends
/// nothing; `diarize` is the upload. One request in flight, no queue, no
/// retries, no redirects, caller-side deadline. There is no text to fall back
/// to, so failures throw `DiarizationError`.
public actor CloudDiarizer: Diarizing {
    /// Longest upload per request, in seconds of audio (about 115 MB of PCM16 WAV).
    public static let maxSeconds: TimeInterval = 3_600
    static let maxResponseBytes = 1_048_576
    /// How far past the audio's end a reported segment may reach.
    static let endTolerance: TimeInterval = 0.5

    private struct Pending {
        let id: UUID
        let entered: ContinuousClock.Instant
        let budget: Duration
        let continuation: CheckedContinuation<SpeakerSegmentation, any Error>
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

    /// Validates configuration only; no request or credential retrieval until `diarize`.
    public static func connect(endpoint: URL, credentials: any CredentialProvider,
                               pack: RemotePack) throws -> CloudDiarizer {
        try CloudTransport.validate(endpoint: endpoint, pack: pack)
        return CloudDiarizer(endpoint: endpoint, credentials: credentials, pack: pack)
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
        guard case .samples16kMono(let samples) = request.audio else {
            throw DiarizationError.invalidRequest("the cloud diarizer accepts samples; decode files on the host")
        }
        guard Double(samples.count) <= Self.maxSeconds * Double(DiarizationRequest.sampleRate) else {
            throw DiarizationError.invalidRequest("the cloud diarizer accepts at most \(Int(Self.maxSeconds / 60)) minutes per request")
        }
        guard !closed else { throw DiarizationError.unavailable("diarizer is closed") }
        guard worker == nil else { throw DiarizationError.busy }
        let budget = request.budget
        let deadline = entered.advanced(by: budget)
        let id = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeakerSegmentation, any Error>) in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.expire(id: id, cancelled: false)
                }
                pending = Pending(id: id, entered: entered, budget: budget, continuation: continuation, timer: timer)
                let session = self.session, endpoint = self.endpoint, credentials = self.credentials, pack = self.pack
                worker = Task.detached { [self] in
                    let outcome: Result<SpeakerSegmentation, any Error>
                    do {
                        outcome = .success(try await Self.send(samples, request: request, id: id, deadline: deadline,
                            session: session, endpoint: endpoint, credentials: credentials, pack: pack))
                    } catch { outcome = .failure(error) }
                    await completed(outcome)
                }
            }
        } onCancel: { Task { await self.expire(id: id, cancelled: true) } }
        try Task.checkCancellation()
        return result
    }

    private static func send(_ samples: [Float], request input: DiarizationRequest, id: UUID,
                             deadline: ContinuousClock.Instant, session: URLSession, endpoint: URL,
                             credentials: any CredentialProvider, pack: RemotePack) async throws -> SpeakerSegmentation {
        let token = try await credentials.bearerToken()
        try Task.checkCancellation()
        guard CloudTransport.isValidBearer(token) else {
            throw DiarizationError.unavailable("invalid bearer credential")
        }
        let remaining = ContinuousClock.now.duration(to: deadline).milliseconds
        guard remaining > 0 else { throw URLError(.timedOut) }
        let seconds = Double(samples.count) / Double(DiarizationRequest.sampleRate)
        var request = URLRequest(url: endpoint, timeoutInterval: remaining / 1_000)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("1", forHTTPHeaderField: "X-Pomvox-Schema")
        request.setValue(pack.id, forHTTPHeaderField: "X-Pomvox-Pack")
        request.setValue(pack.version, forHTTPHeaderField: "X-Pomvox-Pack-Version")
        request.setValue(String(format: "%.3f", seconds), forHTTPHeaderField: "X-Pomvox-Audio-Seconds")
        request.setValue(String(max(1, Int(remaining))), forHTTPHeaderField: "X-Pomvox-Remaining-Milliseconds")
        if let speakers = input.speakers {
            request.setValue("\(speakers.lowerBound)-\(speakers.upperBound)", forHTTPHeaderField: "X-Pomvox-Speakers")
        }
        request.httpBody = WAV.encode16kMono(samples)
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "application/json" else { throw URLError(.badServerResponse) }
        var body = Data()
        for try await byte in stream {
            guard body.count < maxResponseBytes else { throw DiarizationError.invalidResponse("oversized response") }
            body.append(byte)
        }
        let decoded: CloudDiarizationResponse
        do { decoded = try JSONDecoder().decode(CloudDiarizationResponse.self, from: body) }
        catch { throw DiarizationError.invalidResponse("undecodable response") }
        return try validated(decoded, id: id, pack: pack, seconds: seconds)
    }

    /// Everything the client checks before a segmentation reaches the host.
    static func validated(_ response: CloudDiarizationResponse, id: UUID, pack: RemotePack,
                          seconds: TimeInterval) throws -> SpeakerSegmentation {
        func refuse(_ detail: String) -> DiarizationError { .invalidResponse(detail) }
        guard response.schemaVersion == 1 else { throw refuse("schema") }
        guard response.requestID == id else { throw refuse("request id") }
        let result = response.result
        guard result.provenance.packID == pack.id, result.provenance.packVersion == pack.version else { throw refuse("pack") }
        guard result.provenance.route == "cloud", !result.provenance.runtime.isEmpty,
              !result.provenance.artifactDigest.isEmpty, !result.provenance.modelRevision.isEmpty else { throw refuse("provenance") }
        guard result.segments.count <= SpeakerSegmentation.maxSegments else { throw refuse("too many segments") }
        guard result.segments.allSatisfy({ $0.span.isValid && $0.span.end <= seconds + endTolerance
            && ($0.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true) }) else { throw refuse("segment spans") }
        guard result.speakerCount == Set(result.segments.map(\.speaker)).count else { throw refuse("speaker count") }
        guard result.timings.isValid else { throw refuse("timings") }
        guard result.warnings.count <= 64, result.warnings.allSatisfy({ $0.utf8.count <= 256 }) else { throw refuse("warnings") }
        guard !result.segments.isEmpty else { throw DiarizationError.noSpeech }
        let relabeled = result.relabeled()
        guard relabeled.isValid else { throw refuse("segmentation") }
        return relabeled
    }

    private func completed(_ outcome: Result<SpeakerSegmentation, any Error>) {
        defer {
            worker = nil
            // The session may be invalidated only after the worker that used it has returned.
            if closed { session.invalidateAndCancel() }
        }
        guard let pending else { return } // expired, canceled or closed: late output is discarded
        self.pending = nil
        pending.timer.cancel()
        let elapsed = pending.entered.duration(to: .now)
        if elapsed >= pending.budget {
            pending.continuation.resume(throwing: DiarizationError.timedOut); return
        }
        switch outcome {
        case .success(var segmentation):
            segmentation.timings.totalMS = elapsed.milliseconds
            segmentation.timings.budgetMS = pending.budget.milliseconds
            pending.continuation.resume(returning: segmentation)
        case .failure(let error):
            let mapped: any Error
            if let url = error as? URLError {
                mapped = url.code == .timedOut ? DiarizationError.timedOut : DiarizationError.transport(url.localizedDescription)
            } else if error is DiarizationError || error is CancellationError {
                mapped = error
            } else {
                mapped = DiarizationError.transport(String(describing: error))
            }
            pending.continuation.resume(throwing: mapped)
        }
    }

    private func expire(id: UUID, cancelled: Bool) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.timer.cancel()
        worker?.cancel()
        pending.continuation.resume(throwing: cancelled ? CancellationError() : DiarizationError.timedOut)
    }

    /// Stops admission immediately, fails a waiting request and cancels delivery.
    /// The transport session is released when no worker can still touch it.
    public func close() {
        guard !closed else { return }
        closed = true
        if let pending {
            self.pending = nil
            pending.timer.cancel()
            pending.continuation.resume(throwing: DiarizationError.unavailable("diarizer is closed"))
        }
        worker?.cancel()
        if worker == nil { session.invalidateAndCancel() }
    }

    deinit { session.invalidateAndCancel() }
}

/// 16 kHz mono 16-bit PCM WAV, the one audio encoding the diarization protocol accepts.
enum WAV {
    static func encode16kMono(_ samples: [Float]) -> Data {
        let rate: UInt32 = UInt32(DiarizationRequest.sampleRate)
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count * 2))
        for sample in samples {
            let clamped = sample.isFinite ? min(1, max(-1, sample)) : 0
            append(Int16((clamped * 32_767).rounded()))
        }
        return data
    }
}

/// What both cloud clients share: endpoint rules, credential rules, an ephemeral session.
enum CloudTransport {
    static func validate(endpoint: URL, pack: RemotePack) throws {
        let local = ["127.0.0.1", "localhost", "[::1]"].contains(endpoint.host ?? "")
        guard endpoint.scheme == "https" || (endpoint.scheme == "http" && local),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              !pack.id.isEmpty, pack.id.utf8.count <= 64,
              !pack.version.isEmpty, pack.version.utf8.count <= 64 else {
            throw CleanupError.invalidRequest("HTTPS endpoint (or loopback HTTP) and explicit pack version required")
        }
    }

    static func isValidBearer(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 8_192
            && !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
