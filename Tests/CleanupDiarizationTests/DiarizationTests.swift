import CryptoKit
import XCTest
@testable import CleanupDiarization

/// Synthetic packs only: the real bundles are never needed to prove the validator.
final class DiarizerPackLoaderTests: XCTestCase {
    private var root: URL!
    private var pack: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-diarizer-\(UUID().uuidString)")
        pack = root.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try writeSyntheticPack()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSyntheticPack(mutating: [String: Any] = [:]) throws {
        var artifacts: [[String: Any]] = []
        for (index, path) in DiarizerPackLoader.artifactPaths.sorted().enumerated() {
            let url = pack.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(repeating: UInt8(truncatingIfNeeded: index + 1), count: 16 + index)
            try data.write(to: url)
            artifacts.append(["path": path, "bytes": data.count,
                              "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        var manifest: [String: Any] = [
            "schemaVersion": 1, "id": "synthetic-diarizer", "version": "0.0.1", "publisher": "test",
            "license": "CC-BY-4.0", "licenseURL": "https://example.invalid/notice",
            "modelID": "example/synthetic", "modelRevision": String(repeating: "a", count: 40),
            "runtime": DiarizerPackLoader.runtimeVersion, "pipeline": DiarizerPackLoader.pipeline,
            "attribution": ["nobody"], "artifacts": artifacts, "limitations": ["synthetic"], "evidence": "none",
        ]
        for (key, value) in mutating { manifest[key] = value }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: pack.appendingPathComponent("pack.json"))
    }

    func testValidPackValidatesAndDigestCoversTheManifestBytes() throws {
        let validated = try DiarizerPackLoader.validate(directory: pack)
        XCTAssertEqual(validated.manifest.id, "synthetic-diarizer")
        XCTAssertEqual(validated.manifest.artifacts.count, DiarizerPackLoader.artifactPaths.count)
        let bytes = try Data(contentsOf: pack.appendingPathComponent("pack.json"))
        XCTAssertEqual(validated.digest, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(validated.modelsDirectory.lastPathComponent, "pack")
        XCTAssertNoThrow(try DiarizerPackLoader.revalidate(validated))
    }

    func testLayoutIsExact() {
        XCTAssertEqual(DiarizerPackLoader.artifactPaths.count, 23)
        XCTAssertTrue(DiarizerPackLoader.artifactPaths.contains("speaker-diarization/Segmentation.mlmodelc/weights/weight.bin"))
        XCTAssertTrue(DiarizerPackLoader.artifactPaths.contains("speaker-diarization/plda-parameters.json"))
        XCTAssertTrue(DiarizerPackLoader.artifactPaths.allSatisfy { $0.hasPrefix(DiarizerPackLoader.modelsFolder + "/") })
    }

    func testModifiedByteIsRefused() throws {
        let target = pack.appendingPathComponent("speaker-diarization/plda-parameters.json")
        var data = try Data(contentsOf: target)
        data[0] ^= 0xFF
        try data.write(to: target)
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack)) { error in
            guard case CleanupError.invalidPack(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("checksum"), detail)
        }
    }

    func testExtraFileDirectoryAndSymlinkAreRefused() throws {
        try Data("x".utf8).write(to: pack.appendingPathComponent("speaker-diarization/extra.bin"))
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack))
        try FileManager.default.removeItem(at: pack.appendingPathComponent("speaker-diarization/extra.bin"))
        XCTAssertNoThrow(try DiarizerPackLoader.validate(directory: pack))

        try FileManager.default.createDirectory(at: pack.appendingPathComponent("stray"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack))
        try FileManager.default.removeItem(at: pack.appendingPathComponent("stray"))

        let notice = pack.appendingPathComponent("speaker-diarization/NOTICE.md")
        let moved = root.appendingPathComponent("NOTICE.md")
        try FileManager.default.moveItem(at: notice, to: moved)
        try FileManager.default.createSymbolicLink(at: notice, withDestinationURL: moved)
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack))
    }

    func testMissingArtifactWrongRuntimeAndUnknownFieldAreRefused() throws {
        try FileManager.default.removeItem(at: pack.appendingPathComponent("speaker-diarization/LICENSE"))
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack))
        try writeSyntheticPack()
        XCTAssertNoThrow(try DiarizerPackLoader.validate(directory: pack))

        try writeSyntheticPack(mutating: ["runtime": "fluidaudio-9.9.9"])
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack)) { error in
            guard case CleanupError.incompatible = error else { return XCTFail("\(error)") }
        }
        try writeSyntheticPack(mutating: ["surprise": true])
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack))
        try writeSyntheticPack(mutating: ["attribution": []])
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack))
        try writeSyntheticPack(mutating: ["modelRevision": "main"])
        XCTAssertThrowsError(try DiarizerPackLoader.validate(directory: pack))
    }

    func testRevalidateNoticesAChangedFile() throws {
        let validated = try DiarizerPackLoader.validate(directory: pack)
        let target = pack.appendingPathComponent("speaker-diarization/LICENSE")
        try Data("changed".utf8).write(to: target)
        XCTAssertThrowsError(try DiarizerPackLoader.revalidate(validated))
    }

    func testPinnedManifestInRepositoryHasTheSupportedShape() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packs/pyannote-community1-coreml/pack.json")
        let manifest = try JSONDecoder().decode(DiarizerPackManifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(manifest.artifacts.map(\.path)), DiarizerPackLoader.artifactPaths)
        XCTAssertEqual(manifest.runtime, DiarizerPackLoader.runtimeVersion)
        XCTAssertEqual(manifest.pipeline, DiarizerPackLoader.pipeline)
        XCTAssertEqual(manifest.modelRevision, "df2625ac79a7ac6b65ad868fee6d80f320da4232")
        XCTAssertEqual(manifest.license, "CC-BY-4.0")
        XCTAssertTrue(manifest.artifacts.allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 })
    }
}

final class DiarizationTypesTests: XCTestCase {
    private let provenance = Provenance(packID: "p", packVersion: "1.0.0", artifactDigest: "d",
                                        modelRevision: "r", runtime: "test", route: "local")

    func testRequestValidationAndBudget() {
        XCTAssertNoThrow(try DiarizationRequest(samples: [0, 0.1]).validate())
        XCTAssertThrowsError(try DiarizationRequest(samples: []).validate())
        XCTAssertThrowsError(try DiarizationRequest(samples: [0], speakers: 0...2).validate())
        XCTAssertThrowsError(try DiarizationRequest(samples: [0], speakers: 1...51).validate())
        XCTAssertThrowsError(try DiarizationRequest(samples: [0], deadline: .zero).validate())
        XCTAssertThrowsError(try DiarizationRequest(samples: [0], deadline: .seconds(3_601)).validate())
        XCTAssertThrowsError(try DiarizationRequest(audio: .file(URL(string: "https://example.invalid/a.wav")!)).validate())
        XCTAssertNoThrow(try DiarizationRequest(audio: .file(URL(fileURLWithPath: "/tmp/a.wav"))).validate())
        XCTAssertEqual(DiarizationRequest(samples: [0]).budget, .seconds(60))
        XCTAssertEqual(DiarizationRequest(samples: Array(repeating: 0, count: 16_000 * 600)).budget, .seconds(300))
        XCTAssertEqual(DiarizationRequest(samples: [0], deadline: .seconds(7)).budget, .seconds(7))
        XCTAssertEqual(DiarizationRequest(audio: .file(URL(fileURLWithPath: "/tmp/a.wav"))).budget, .seconds(600))
        XCTAssertEqual(DiarizationRequest(samples: Array(repeating: 0, count: 32_000)).audioSeconds, 2)
    }

    func testRelabelingIsFirstAppearanceOrderAndSorted() {
        let raw = SpeakerSegmentation(segments: [
            SpeakerSegment(speaker: SpeakerLabel("7"), span: TimeSpan(start: 5, end: 6)),
            SpeakerSegment(speaker: SpeakerLabel("2"), span: TimeSpan(start: 0, end: 1)),
            SpeakerSegment(speaker: SpeakerLabel("7"), span: TimeSpan(start: 2, end: 3)),
        ], speakerCount: 2, provenance: provenance)
        let labeled = raw.relabeled()
        XCTAssertEqual(labeled.segments.map(\.speaker.rawValue), ["S1", "S2", "S2"])
        XCTAssertEqual(labeled.segments.map(\.span.start), [0, 2, 5])
        XCTAssertEqual(labeled.speakers.map(\.rawValue), ["S1", "S2"])
        XCTAssertEqual(labeled.speakerCount, 2)
        XCTAssertTrue(labeled.isValid)
        XCTAssertFalse(raw.isValid) // unsorted
    }

    func testValidityRules() {
        let bad = SpeakerSegmentation(segments: [SpeakerSegment(speaker: SpeakerLabel("S1"), span: TimeSpan(start: 1, end: 0))],
                                      speakerCount: 1, provenance: provenance)
        XCTAssertFalse(bad.isValid)
        let miscounted = SpeakerSegmentation(segments: [SpeakerSegment(speaker: SpeakerLabel("S1"), span: TimeSpan(start: 0, end: 1))],
                                             speakerCount: 2, provenance: provenance)
        XCTAssertFalse(miscounted.isValid)
        var timings = DiarizationTimings()
        timings.totalMS = -1
        XCTAssertFalse(timings.isValid)
        let confident = SpeakerSegmentation(segments: [SpeakerSegment(speaker: SpeakerLabel("S1"), span: TimeSpan(start: 0, end: 1), confidence: 1.5)],
                                            speakerCount: 1, provenance: provenance)
        XCTAssertFalse(confident.isValid)
        XCTAssertTrue(SpeakerSegmentation(segments: [], speakerCount: 0, provenance: provenance).isValid)
    }

    func testCodableRoundTrip() throws {
        let value = SpeakerSegmentation(segments: [SpeakerSegment(speaker: SpeakerLabel("S1"), span: TimeSpan(start: 0, end: 1.5), confidence: 0.9)],
                                        speakerCount: 1, provenance: provenance, warnings: ["w"])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerSegmentation.self, from: data), value)
    }
}

/// A conformer that implements only `diarize` and `close` still gets `closeAndWait`.
private actor MinimalDiarizer: Diarizing {
    private(set) var closes = 0
    func diarize(_ request: DiarizationRequest) async throws -> SpeakerSegmentation {
        throw DiarizationError.unavailable("test double")
    }
    func close() { closes += 1 }
}

final class DiarizingDefaultsTests: XCTestCase {
    func testDefaultCloseAndWaitClosesAndHonoursCancellation() async throws {
        let diarizer = MinimalDiarizer()
        try await diarizer.closeAndWait()
        let closes = await diarizer.closes
        XCTAssertEqual(closes, 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await diarizer.closeAndWait()
        }
        do { try await cancelled.value; XCTFail("a canceled wait must throw") } catch is CancellationError {}
        let closedAgain = await diarizer.closes
        XCTAssertEqual(closedAgain, 2, "cancellation stops the wait, not the close")
    }
}
