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
        // Preserve the app's length-aware budget explicitly, without its reload credit.
        let budget = min(60, max(timeoutSeconds, (0.6 + Double(raw.count) / 110) * 1.4))
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
        insert(final) // No suspension between session validation and insertion.
        return result
    }
}
