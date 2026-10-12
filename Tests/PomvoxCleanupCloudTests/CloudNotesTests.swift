import XCTest
@testable import PomvoxCleanupCloud

private struct Credentials: CredentialProvider {
    func bearerToken() async throws -> String { "test-only-token" }
}

final class CloudNotesTests: XCTestCase, @unchecked Sendable {
    private func server() throws -> (Process, Int) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock_server.py").path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        return (process, try XCTUnwrap(Int(String(decoding: line, as: UTF8.self))))
    }

    /// `Process.waitUntilExit()` has been seen to never return after `terminate()` once the
    /// child was already gone; reap the fixture with waitpid, which returns either way.
    private func stop(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
    }

    private func client(_ port: Int, _ path: String) throws -> CloudNotes {
        try CloudNotes.connect(endpoint: URL(string: "http://127.0.0.1:\(port)/n/\(path)")!,
                               credentials: Credentials(), pack: RemotePack(id: "notes-test", version: "1.0.0"))
    }

    private let provenance = Provenance(packID: "p", packVersion: "1.0.0", artifactDigest: "d",
                                        modelRevision: "r", runtime: "test", route: "local")

    private func source(_ count: Int = 3) -> TranscriptResult {
        TranscriptResult(turns: (0..<count).map { index in
            let turn = SpeakerTurn(speaker: SpeakerLabel("S\(index % 2 + 1)"), text: "Turn \(index) says something.",
                                   span: TimeSpan(start: Double(index) * 5, end: Double(index) * 5 + 4))
            return TurnResult(turn: turn, result: CleanupResult(text: turn.text, edits: [], status: .unchanged, provenance: provenance))
        }, elapsedMS: 1)
    }

    func testSuccessValidatesCitationsAndReportsClientTimings() async throws {
        let (server, port) = try server()
        defer { stop(server) }
        let remote = try client(port, "ok")
        let notes = try await remote.write(for: source(), options: NotesWriteOptions(style: "meeting", deadline: .seconds(5)))
        XCTAssertEqual(notes.summary.count, 1)
        XCTAssertEqual(notes.summary[0].turns, [0, 2])
        XCTAssertEqual(notes.actionItems.map(\.turns), [[1]])
        XCTAssertEqual(notes.provenance.route, "cloud")
        XCTAssertEqual(notes.timings.serverInferenceMS, 3)
        XCTAssertEqual(notes.timings.budgetMS, 5_000)
        XCTAssertGreaterThan(notes.timings.totalMS, 0)
        XCTAssertEqual(notes.warnings, ["mock-only"])
        let rendered = NotesRenderer.markdown(Notes.extract(from: source()), model: notes,
                                              options: NotesRenderer.Options(speakerNames: [SpeakerLabel("S1"): "Abhi"]))
        XCTAssertTrue(rendered.contains("## Summary\n- The speakers planned the release and assigned the report. — Abhi 0:00, Abhi 0:10\n"), rendered)
        XCTAssertTrue(rendered.contains("## Action items (model)\n- Send the updated report by Friday. — S2 0:05\n"), rendered)
        XCTAssertTrue(rendered.contains("## Transcript"))
        await remote.close()
    }

    func testAdversarialResponsesNeverReachTheHost() async throws {
        let (server, port) = try server()
        defer { stop(server) }
        let invalid = ["wrongid", "wrongschema", "wrongpack", "wrongroute", "badcitation", "nocitation", "emptytext",
                       "multiline", "toomany", "negative", "missingfield", "truncated", "oversized"]
        for path in invalid + ["http500", "wrongmime", "redirect"] {
            let remote = try client(port, path)
            do {
                _ = try await remote.write(for: source(), options: NotesWriteOptions(deadline: .seconds(5)))
                XCTFail("\(path) must throw")
            } catch let error as ModelNotesError {
                switch error {
                case .invalidResponse: XCTAssertTrue(invalid.contains(path), path)
                case .transport: XCTAssertFalse(invalid.contains(path), path)
                default: XCTFail("\(path): unexpected \(error)")
                }
            }
            await remote.close()
        }
    }

    func testBusyTimeoutCancellationAndClose() async throws {
        let (server, port) = try server()
        defer { stop(server) }
        let slow = try client(port, "slow")
        let start = ContinuousClock.now
        do {
            _ = try await slow.write(for: source(), options: NotesWriteOptions(deadline: .milliseconds(80)))
            XCTFail("must time out")
        } catch ModelNotesError.timedOut {}
        XCTAssertLessThan(start.duration(to: .now).milliseconds, 300)
        var waited = 0
        while await slow.availability != .ready, waited < 100 { try await Task.sleep(for: .milliseconds(20)); waited += 1 }
        let inFlight = Task { try await slow.write(for: self.source(), options: NotesWriteOptions(deadline: .seconds(5))) }
        try await Task.sleep(for: .milliseconds(50))
        do { _ = try await slow.write(for: source()); XCTFail("second request must be refused") }
        catch ModelNotesError.busy {}
        _ = try await inFlight.value
        let cancelled = Task { try await slow.write(for: self.source(), options: NotesWriteOptions(deadline: .seconds(5))) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("must throw") } catch is CancellationError {}
        await slow.close()
        do { _ = try await slow.write(for: source()); XCTFail("closed must refuse") }
        catch ModelNotesError.unavailable {}
    }

    func testRequestLimitsAndConfigurationAreRefusedBeforeAnyUpload() async throws {
        let remote = try CloudNotes.connect(endpoint: URL(string: "http://127.0.0.1:1/n/ok")!,
                                            credentials: Credentials(), pack: RemotePack(id: "notes-test", version: "1.0.0"))
        do { _ = try await remote.write(for: source(0)); XCTFail("empty must be refused") } catch ModelNotesError.invalidRequest {}
        do { _ = try await remote.write(for: source(Transcript.maxTurns + 1)); XCTFail("too many turns") } catch ModelNotesError.invalidRequest {}
        do {
            _ = try await remote.write(for: source(), options: NotesWriteOptions(style: String(repeating: "x", count: 65)))
            XCTFail("long style")
        } catch ModelNotesError.invalidRequest {}
        do { _ = try await remote.write(for: source(), options: NotesWriteOptions(deadline: .zero)); XCTFail("zero deadline") }
        catch ModelNotesError.invalidRequest {}
        let huge = TranscriptResult(turns: [TurnResult(turn: SpeakerTurn(text: "x"),
            result: CleanupResult(text: String(repeating: "y", count: CloudNotes.maxTranscriptBytes + 1), edits: [],
                                  status: .unchanged, provenance: provenance))], elapsedMS: 0)
        do { _ = try await remote.write(for: huge); XCTFail("oversized transcript") } catch ModelNotesError.invalidRequest {}
        await remote.close()
        XCTAssertThrowsError(try CloudNotes.connect(endpoint: URL(string: "http://example.org/n")!, credentials: Credentials(),
                                                    pack: RemotePack(id: "notes-test", version: "1.0.0")))
    }

    func testInvalidCredentialsNeverBecomeHeaders() async throws {
        struct Invalid: CredentialProvider {
            let token: String
            func bearerToken() async throws -> String { token }
        }
        for token in ["", "secret\r\nInjected: value", String(repeating: "x", count: 8_193), "secret\0"] {
            let remote = try CloudNotes.connect(endpoint: URL(string: "http://127.0.0.1:1/n/ok")!,
                                                credentials: Invalid(token: token), pack: RemotePack(id: "notes-test", version: "1.0.0"))
            do { _ = try await remote.write(for: source()); XCTFail("must throw") }
            catch ModelNotesError.unavailable {}
            await remote.close()
        }
    }
}
