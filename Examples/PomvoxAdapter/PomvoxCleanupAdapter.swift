import Foundation
import PomvoxCleanup

/// Example seam only. Pomvox's microphone, insertion and dictionary implementations stay in the host.
@MainActor
final class PomvoxCleanupAdapter {
    private let cleaner: any Cleaning
    private var currentSession = UUID()
    private var task: Task<CleanupResult, any Error>?

    init(cleaner: any Cleaning) { self.cleaner = cleaner }

    func cancel() {
        currentSession = UUID()
        task?.cancel()
    }

    /// Host supplies its existing transforms; the SDK itself never applies them.
    func finish(raw: String, vocabulary: [String], timeoutSeconds: Double,
                spokenFormatting: (String) -> String,
                dictionary: (String) -> String,
                signature: (String) -> String,
                insert: (String) -> Void) async throws -> CleanupResult {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw CleanupError.invalidRequest("host timeout must be finite and positive")
        }
        try Task.checkCancellation()
        cancel() // Supersede any prior session, including a late non-cooperative generation.
        let session = currentSession
        defer { if currentSession == session { task = nil } }
        let cleaner = self.cleaner
        // The host has already chosen its remaining budget, including preparation time.
        // A long transcript must never silently extend that explicit deadline.
        let budget = min(60, timeoutSeconds)
        let running = Task { try await cleaner.clean(CleanupRequest(raw, vocabulary: vocabulary,
                                                                    deadline: .seconds(budget))) }
        task = running
        let result = try await withTaskCancellationHandler {
            try await running.value
        } onCancel: { running.cancel() }
        try Task.checkCancellation()
        guard currentSession == session else { throw CancellationError() }
        // result is also the evaluation-capture point, before host transforms.
        let formatted = spokenFormatting(result.text)
        let corrected = dictionary(formatted)
        let final = signature(corrected)
        // Host callbacks can retire this session synchronously; cancellation can also
        // arrive from another task while transforms execute.
        try Task.checkCancellation()
        guard currentSession == session else { throw CancellationError() }
        insert(final) // No suspension or host callback between this check and insertion.
        return result
    }
}
