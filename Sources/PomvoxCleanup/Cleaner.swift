@_exported import CleanupCore
@_exported import CleanupPacks
import Foundation

public enum LocalPolicy: Sendable { case local }
public enum PackSource: Sendable { case directory(URL), validated(ValidatedPack) }

public struct RuntimeFactory: Sendable {
    public let name: String
    public let make: @Sendable (ValidatedPack) async throws -> any CleanupRuntime
    public init(name: String, make: @escaping @Sendable (ValidatedPack) async throws -> any CleanupRuntime) {
        self.name = name; self.make = make
    }
}

public final class Cleaner: Cleaning, Sendable {
    public let pack: ValidatedPack
    public let preparationMS: Double
    private let session: CleanupSession

    private init(pack: ValidatedPack, session: CleanupSession, preparationMS: Double) {
        self.pack = pack; self.session = session; self.preparationMS = preparationMS
    }

    public static func open(pack source: PackSource, runtime: RuntimeFactory,
                            policy: LocalPolicy = .local) async throws -> Cleaner {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        let directory = switch source {
        case .directory(let url): url.standardizedFileURL.resolvingSymlinksInPath()
        case .validated(let pack): pack.directory
        }
        // Held before validation: a concurrent `PackInstaller.remove` either refuses or makes validation fail.
        // The session's runtime keeps the hold once opened; every earlier exit releases it here.
        let hold = OpenPacks.shared.hold(directory)
        var opened = false
        defer { if !opened { hold.release() } }
        let validation = Task.detached {
            switch source {
            case .directory(let url): return try PackLoader.validate(directory: url)
            case .validated(let pack): return try PackLoader.revalidate(pack)
            }
        }
        let pack = try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        let backend = try await runtime.make(pack)
        do { try Task.checkCancellation() }
        catch { await backend.close(); throw error }
        let preparation = start.duration(to: .now).milliseconds
        let provenance = Provenance(packID: pack.manifest.id, packVersion: pack.manifest.version,
            artifactDigest: pack.digest, modelRevision: pack.manifest.modelRevision,
            runtime: runtime.name, route: "local", settings: ["prompt": pack.manifest.prompt,
                "temperature": "0", "enable_thinking": "false"])
        let session = try CleanupSession(runtime: HeldRuntime(runtime: backend, hold: hold),
                                         provenance: provenance, preparationMS: preparation)
        opened = true
        return Cleaner(pack: pack, session: session, preparationMS: preparation)
    }

    public func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        try Task.checkCancellation()
        try request.validate()
        guard request.context.isEmpty, request.settings.isEmpty else {
            throw CleanupError.incompatible("the frozen baseline supports vocabulary, not context or style settings")
        }
        guard capabilities.vocabulary.admits(request.vocabulary) else {
            throw CleanupError.incompatible("vocabulary exceeds this pack's declared limits")
        }
        return try await session.clean(request)
    }

    public var packIdentity: PackIdentity? {
        PackIdentity(id: pack.manifest.id, version: pack.manifest.version, digest: pack.digest)
    }

    /// What the opened pack supports; the same answer as `pack.capabilities` before open.
    public var capabilities: PackCapabilities { pack.capabilities }

    /// A snapshot, not an admission reservation. Never start a second model to bypass quarantine.
    public var availability: CleanerAvailability { get async { await session.availability } }

    /// Waits for actual resource release; cancellation stops waiting, never reopens admission.
    public func closeAndWait() async throws {
        await session.close()
        while !(await session.resourcesReleased) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }

    public func close() async { await session.close() }
}

/// Keeps the pack directory marked as held until the runtime's resources are actually released.
private struct HeldRuntime: CleanupRuntime {
    let runtime: any CleanupRuntime
    let hold: PackHold
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        try await runtime.generate(request, deadline: deadline)
    }
    func close() async { await runtime.close(); hold.release() }
}
