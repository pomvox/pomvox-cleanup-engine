@_exported import CleanupCore
import Foundation

public protocol CredentialProvider: Sendable {
    func bearerToken() async throws -> String
}

public struct RemotePack: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public init(id: String, version: String) { self.id = id; self.version = version }
}

public struct CloudRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let pack: RemotePack
    public let text: String
    public let vocabulary: [String]
    public let context: String
    public let settings: [String: String]
    public let remainingMilliseconds: Int
}

public struct CloudResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let result: CleanupResult
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Explicit remote transport preview. One in-flight operation, no retries or route changes.
public actor CloudCleaner: Cleaning {
    private struct Pending {
        let id: UUID
        let input: CleanupRequest
        let entered: ContinuousClock.Instant
        let continuation: CheckedContinuation<CleanupResult, any Error>
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
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// Validates configuration only; no request or credential retrieval until clean.
    public static func connect(endpoint: URL, credentials: any CredentialProvider,
                               pack: RemotePack) throws -> CloudCleaner {
        let local = ["127.0.0.1", "localhost", "[::1]"].contains(endpoint.host ?? "")
        guard endpoint.scheme == "https" || (endpoint.scheme == "http" && local),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              !pack.id.isEmpty, pack.id.utf8.count <= 64,
              !pack.version.isEmpty, pack.version.utf8.count <= 64 else {
            throw CleanupError.invalidRequest("HTTPS endpoint (or loopback HTTP) and explicit pack version required")
        }
        return CloudCleaner(endpoint: endpoint, credentials: credentials, pack: pack)
    }

    public func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        let entered = ContinuousClock.now
        try Task.checkCancellation()
        try request.validate()
        guard !closed else { return fallback(request, .unavailable, entered: entered) }
        if request.text.isEmpty {
            let skipped = fallback(request, .unavailable, entered: entered)
            return CleanupResult(text: "", edits: [], status: .unchanged,
                provenance: skipped.provenance, timings: skipped.timings,
                warnings: ["empty-input-no-remote-execution"])
        }
        guard worker == nil else { return fallback(request, .busy, entered: entered) }
        let deadline = entered.advanced(by: request.budget)
        let id = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.expire(id: id, cancelled: false)
                }
                pending = Pending(id: id, input: request, entered: entered, continuation: continuation, timer: timer)
                let session = self.session, endpoint = self.endpoint, credentials = self.credentials, pack = self.pack
                worker = Task.detached { [self] in
                    let result: Result<CleanupResult, any Error>
                    do {
                        result = .success(try await Self.send(request, id: id, deadline: deadline,
                            session: session, endpoint: endpoint, credentials: credentials, pack: pack))
                    } catch { result = .failure(error) }
                    await completed(result)
                }
            }
        } onCancel: { Task { await self.expire(id: id, cancelled: true) } }
        try Task.checkCancellation()
        return result
    }

    private static func send(_ input: CleanupRequest, id: UUID, deadline: ContinuousClock.Instant,
                             session: URLSession, endpoint: URL, credentials: any CredentialProvider,
                             pack: RemotePack) async throws -> CleanupResult {
        let token = try await credentials.bearerToken()
        try Task.checkCancellation()
        guard !token.isEmpty, token.utf8.count <= 8_192,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CleanupError.invalidRequest("invalid bearer credential")
        }
        let remaining = ContinuousClock.now.duration(to: deadline).milliseconds
        guard remaining > 0 else { throw URLError(.timedOut) }
        let payload = CloudRequest(schemaVersion: 1, requestID: id, pack: pack, text: input.text,
            vocabulary: input.vocabulary, context: input.context, settings: input.settings,
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
            guard body.count < 131_072 else { throw CleanupError.invalidRequest("oversized response") }
            body.append(byte)
        }
        let responseBody = try JSONDecoder().decode(CloudResponse.self, from: body)
        let result = responseBody.result
        guard responseBody.schemaVersion == 1, responseBody.requestID == id,
              result.provenance.packID == pack.id, result.provenance.packVersion == pack.version,
              result.provenance.route == "cloud", !result.provenance.runtime.isEmpty,
              !result.provenance.artifactDigest.isEmpty, !result.provenance.modelRevision.isEmpty,
              result.text.utf8.count <= 65_536, result.edits.count <= 1_024,
              try TextEdit.applying(result.edits, to: input.text).utf8.elementsEqual(result.text.utf8)
        else { throw CleanupError.invalidEdits }
        let identical = result.text.utf8.elementsEqual(input.text.utf8)
        switch result.status {
        case .cleaned: guard !identical, !result.edits.isEmpty else { throw CleanupError.invalidEdits }
        case .unchanged, .fallback:
            guard identical, result.edits.isEmpty else { throw CleanupError.invalidEdits }
        }
        guard result.timings.isValid else { throw CleanupError.invalidEdits }
        return result
    }

    private func completed(_ output: Result<CleanupResult, any Error>) {
        defer { worker = nil }
        guard let pending else { return }
        self.pending = nil
        pending.timer.cancel()
        let elapsed = pending.entered.duration(to: .now).milliseconds
        let result: CleanupResult
        if elapsed >= pending.input.budget.milliseconds {
            result = fallback(pending.input, .timedOut, entered: pending.entered)
        } else {
            switch output {
            case .success(var response):
                response.timings.serverInferenceMS = response.timings.inferenceMS
                response.timings.totalMS = elapsed
                response.timings.budgetMS = pending.input.budget.milliseconds
                result = response
            case .failure(let error):
                let reason: FallbackReason
                if (error as? URLError)?.code == .timedOut { reason = .timedOut }
                else { reason = error is DecodingError || error is CleanupError ? .invalidResponse : .transport }
                result = fallback(pending.input, reason, entered: pending.entered)
            }
        }
        pending.continuation.resume(returning: result)
    }

    private func expire(id: UUID, cancelled: Bool) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.timer.cancel()
        worker?.cancel()
        if cancelled { pending.continuation.resume(throwing: CancellationError()) }
        else { pending.continuation.resume(returning: fallback(pending.input, .timedOut, entered: pending.entered)) }
    }

    private func fallback(_ request: CleanupRequest, _ reason: FallbackReason,
                          entered: ContinuousClock.Instant) -> CleanupResult {
        var timings = CleanupTimings()
        timings.totalMS = entered.duration(to: .now).milliseconds
        timings.budgetMS = request.budget.milliseconds
        return CleanupResult(text: request.text, edits: [], status: .fallback(reason),
            provenance: Provenance(packID: pack.id, packVersion: pack.version, artifactDigest: "unavailable",
                modelRevision: "unavailable", runtime: "unavailable", route: "cloud"), timings: timings)
    }

    public func close() {
        closed = true
        if let pending { expire(id: pending.id, cancelled: true) }
        session.invalidateAndCancel()
    }

    deinit { session.invalidateAndCancel() }
}
