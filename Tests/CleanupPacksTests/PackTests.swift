import XCTest
import CryptoKit
import Darwin
import PomvoxCleanup
@testable import CleanupPacks

final class PackTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["config.json": "{}", "tokenizer.json": "{}", "tokenizer_config.json": "{}",
                     "chat_template.jinja": "test", "model.safetensors": "fake-test-artifact",
                     "model.safetensors.index.json": "{\"weight_map\":{\"test\":\"model.safetensors\"}}", "system_v2.txt": "test prompt"]
        var artifacts: [[String: Any]] = []
        for (name, contents) in files {
            let data = Data(contents.utf8)
            try data.write(to: root.appendingPathComponent(name))
            artifacts.append(["path": name, "bytes": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "id": "test", "version": "1.0.0", "publisher": "tests",
            "license": "MIT", "licenseURL": "https://example.org/license", "modelID": "test/model",
            "modelRevision": String(repeating: "a", count: 40), "runtime": PackLoader.runtimeVersion,
            "prompt": "simplewords-frozen-v2", "quantization": "8bit", "languages": ["en"],
            "capabilities": ["vocabulary"], "rules": ["pomvox-guards-v0.2.8"], "artifacts": artifacts,
            "limitations": ["test only"], "evidence": "deterministic fixture; not a model"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("pack.json"))
        return root
    }

    func testValidAndTamperedArtifact() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackLoader.validate(directory: root)
        XCTAssertEqual(pack.manifest.id, "test")
        try Data("evil".utf8).write(to: root.appendingPathComponent("system_v2.txt"))
        XCTAssertThrowsError(try PackLoader.validate(directory: root))
    }

    func testRejectsSymlinksAndUnexpectedWeights() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("adapter.safetensors"),
                                                   withDestinationURL: root.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try PackLoader.validate(directory: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("adapter.safetensors"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("system_v2.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("system_v2.txt"),
                                                   withDestinationURL: root.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try PackLoader.validate(directory: root))
    }

    func testRejectsIncompatibleAndTraversalManifests() throws {
        for mutation in ["runtime", "rules", "path", "schemaVersion", "bytes", "sha256", "unsupportedSettings"] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("pack.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            switch mutation {
            case "runtime": json[mutation] = "future-runtime"
            case "rules": json[mutation] = ["execute-shell"]
            case "schemaVersion": json[mutation] = 2
            case "unsupportedSettings": json["settings"] = ["style": "ignored"]
            default:
                var artifacts = json["artifacts"] as! [[String: Any]]
                if mutation == "path" { artifacts[0][mutation] = "../outside" }
                if mutation == "bytes" { artifacts[0][mutation] = -1 }
                if mutation == "sha256" { artifacts[0][mutation] = String(repeating: "0", count: 64) }
                json["artifacts"] = artifacts
            }
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            XCTAssertThrowsError(try PackLoader.validate(directory: root), mutation)
        }
    }
}

extension PackTests {
    private func mutateManifest(_ root: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = root.appendingPathComponent("pack.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        mutate(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func replaceArtifact(_ root: URL, name: String, contents: String) throws {
        let data = Data(contents.utf8)
        try data.write(to: root.appendingPathComponent(name))
        try mutateManifest(root) { manifest in
            var artifacts = manifest["artifacts"] as! [[String: Any]]
            let index = artifacts.firstIndex { $0["path"] as? String == name }!
            artifacts[index]["bytes"] = data.count
            artifacts[index]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            manifest["artifacts"] = artifacts
        }
    }

    func testStrictManifestFieldAndIdentityMatrix() throws {
        let mutations: [(String, Any)] = [
            ("schemaVersion", true), ("schemaVersion", "1"), ("id", "../outside"),
            ("id", String(repeating: "a", count: 65)), ("version", "01.0.0"),
            ("version", "1.0.0-.."), ("version", "1.0"), ("modelRevision", "main"),
            ("modelRevision", String(repeating: "A", count: 40)), ("publisher", ""),
            ("license", ""), ("evidence", ""), ("limitations", []),
            ("languages", ["en", "fr"]), ("capabilities", ["vocabulary", "code"]),
            ("prompt", "new-prompt"), ("quantization", "4bit"), ("extra", true)]
        for (field, value) in mutations {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try mutateManifest(root) { $0[field] = value }
            XCTAssertThrowsError(try PackLoader.validate(directory: root), "\(field): \(value)")
        }
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try mutateManifest(root) { manifest in
            var artifacts = manifest["artifacts"] as! [[String: Any]]
            artifacts[0]["downloadURL"] = "https://example.org/untrusted"
            manifest["artifacts"] = artifacts
        }
        XCTAssertThrowsError(try PackLoader.validate(directory: root))
    }

    func testMissingDuplicateAndOversizedArtifacts() throws {
        for kind in ["missing", "duplicate", "oversized", "zero", "nested"] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try mutateManifest(root) { manifest in
                var artifacts = manifest["artifacts"] as! [[String: Any]]
                switch kind {
                case "missing": artifacts.removeLast()
                case "duplicate": artifacts[0] = artifacts[1]
                case "oversized": artifacts[0]["bytes"] = Int.max
                case "zero": artifacts[0]["bytes"] = 0
                default: artifacts[0]["path"] = "nested/config.json"
                }
                manifest["artifacts"] = artifacts
            }
            XCTAssertThrowsError(try PackLoader.validate(directory: root), kind)
        }
    }

    func testManifestMustBeBoundedRegularFile() throws {
        for kind in ["directory", "fifo", "symlink", "oversized", "invalidJSON", "array"] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("pack.json")
            try FileManager.default.removeItem(at: url)
            switch kind {
            case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case "fifo": XCTAssertEqual(mkfifo(url.path, 0o600), 0)
            case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("config.json"))
            case "oversized": try Data(repeating: 32, count: 65_537).write(to: url)
            case "array": try Data("[]".utf8).write(to: url)
            default: try Data("{".utf8).write(to: url)
            }
            XCTAssertThrowsError(try PackLoader.validate(directory: root), kind)
        }
    }

    func testVerifiedMetadataCannotReferenceCodeOrUnverifiedWeights() throws {
        for (name, contents) in [
            ("tokenizer_config.json", "{\"auto_map\":{\"AutoTokenizer\":\"execute.py\"}}"),
            ("tokenizer_config.json", "[]"),
            ("model.safetensors.index.json", "{\"weight_map\":{\"x\":\"../outside\"}}"),
            ("model.safetensors.index.json", "{\"weight_map\":{}}"),
            ("model.safetensors.index.json", "{}"), ("system_v2.txt", " \n\t")
        ] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try replaceArtifact(root, name: name, contents: contents)
            XCTAssertThrowsError(try PackLoader.validate(directory: root), name)
        }
    }

    func testHashRejectsRemoteSymlinkAndFIFOAndMatchesKnownVector() throws {
        XCTAssertThrowsError(try PackLoader.hash(URL(string: "https://example.org/file")!))
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vector")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try PackLoader.hash(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try PackLoader.hash(link))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try PackLoader.hash(fifo))
    }

    func testCancelledHashStopsBeforeReading() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PackLoader.validate(directory: root)
        }
        do { _ = try await task.value; XCTFail("cancellation must throw") }
        catch is CancellationError {}
    }
}

private actor SetupRuntime: CleanupRuntime {
    var calls = 0
    var closes = 0
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) -> RuntimeOutput {
        calls += 1
        return RuntimeOutput(candidate: request.text)
    }
    func close() { closes += 1 }
    func state() -> (Int, Int) { (calls, closes) }
}

extension PackTests {
    func testPublicFacadePreparationProvenanceAndRejectedSettings() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SetupRuntime()
        let cleaner = try await Cleaner.open(pack: .directory(root), runtime: RuntimeFactory(name: "test-runtime") { pack in
            XCTAssertEqual(pack.manifest.id, "test")
            return runtime
        })
        XCTAssertGreaterThan(cleaner.preparationMS, 0)
        let result = try await cleaner.clean("hello")
        XCTAssertEqual(result.status, .unchanged)
        XCTAssertEqual(result.provenance.runtime, "test-runtime")
        XCTAssertEqual(result.provenance.artifactDigest, cleaner.pack.digest)
        XCTAssertEqual(result.timings.preparationMS, cleaner.preparationMS)
        for input in [CleanupRequest("hello", context: "unsupported"),
                      CleanupRequest("hello", settings: ["style": "polish"])] {
            do { _ = try await cleaner.clean(input); XCTFail("baseline must reject unsupported settings") }
            catch CleanupError.incompatible {}
        }
        await cleaner.close(); await cleaner.close()
        let state = await runtime.state()
        XCTAssertEqual(state.0, 1); XCTAssertEqual(state.1, 1)
        let closed = try await cleaner.clean("hello")
        XCTAssertEqual(closed.status, .fallback(.unavailable))
    }

    func testInvalidPackNeverConstructsRuntime() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("bad".utf8).write(to: root.appendingPathComponent("system_v2.txt"))
        do {
            _ = try await Cleaner.open(pack: .directory(root), runtime: RuntimeFactory(name: "must-not-run") { _ in
                XCTFail("invalid assets must fail before allocation")
                return SetupRuntime()
            })
            XCTFail("invalid pack must throw")
        } catch {}
    }

    func testPreparationCancellationReleasesConstructedRuntime() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SetupRuntime()
        let task = Task {
            try await Cleaner.open(pack: .directory(root), runtime: RuntimeFactory(name: "cancelled-factory") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return runtime
            })
        }
        do { _ = try await task.value; XCTFail("cancellation must throw") }
        catch is CancellationError {}
        let state = await runtime.state()
        XCTAssertEqual(state.0, 0); XCTAssertEqual(state.1, 1)
    }

    func testFactoryFailurePropagatesWithoutReturningHalfOpenCleaner() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await Cleaner.open(pack: .directory(root), runtime: RuntimeFactory(name: "failure") { _ in
                throw CleanupError.unavailable("injected allocation failure")
            })
            XCTFail("setup failure must throw")
        } catch { XCTAssertEqual(error as? CleanupError, .unavailable("injected allocation failure")) }
    }
}

extension PackTests {
    func testInstallerClonesSnapshotSymlinksAndRefusesOverwrite() throws {
        let source = try fixture()
        let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let manifest = try Data(contentsOf: source.appendingPathComponent("pack.json"))
        let weights = source.appendingPathComponent("model.safetensors")
        let blob = source.appendingPathComponent("blob")
        try FileManager.default.moveItem(at: weights, to: blob)
        try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: blob)
        let installed = try PackInstaller.install(snapshot: source, manifestData: manifest, destination: destination)
        XCTAssertEqual(installed.manifest.id, "test")
        XCTAssertNoThrow(try PackLoader.revalidate(installed))
        XCTAssertThrowsError(try PackInstaller.install(snapshot: source, manifestData: manifest, destination: destination))
        try Data("modified source".utf8).write(to: blob)
        XCTAssertNoThrow(try PackLoader.validate(directory: destination))
    }

    func testInstallerCorruptionDoesNotPublish() throws {
        let source = try fixture()
        let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let manifest = try Data(contentsOf: source.appendingPathComponent("pack.json"))
        try Data("evil prompt".utf8).write(to: source.appendingPathComponent("system_v2.txt"))
        XCTAssertThrowsError(try PackInstaller.install(snapshot: source, manifestData: manifest, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

extension PackTests {
    func testValidatedPackReuseRejectsChangesAndReplacement() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let pack = try PackLoader.validate(directory: source)
        XCTAssertNoThrow(try PackLoader.revalidate(pack))
        // Same length, different bytes; size-only checks would miss this.
        try Data("evil prompt".utf8).write(to: source.appendingPathComponent("system_v2.txt"))
        XCTAssertThrowsError(try PackLoader.revalidate(pack))
    }
}

extension PackTests {
    func testConcurrentNativeInstallersPublishExactlyOnePack() async throws {
        let source = try fixture()
        let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let manifest = try Data(contentsOf: source.appendingPathComponent("pack.json"))
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try PackInstaller.install(snapshot: source, manifestData: manifest, destination: destination)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertNoThrow(try PackLoader.validate(directory: destination))
    }

    func testCleanerReopensValidatedPackAfterResourceRelease() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let firstRuntime = SetupRuntime()
        let first = try await Cleaner.open(pack: .directory(source), runtime: RuntimeFactory(name: "first") { _ in firstRuntime })
        let pack = first.pack
        try await first.closeAndWait()
        let state = await firstRuntime.state()
        XCTAssertEqual(state.1, 1)
        let second = try await Cleaner.open(pack: .validated(pack), runtime: RuntimeFactory(name: "second") { _ in SetupRuntime() })
        let result = try await second.clean("hello")
        XCTAssertEqual(result.status, .unchanged)
        XCTAssertEqual(second.pack.digest, pack.digest)
        try await second.closeAndWait()
    }
}
