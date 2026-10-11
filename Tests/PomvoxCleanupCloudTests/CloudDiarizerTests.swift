// The loopback fixture is a Python child process; Foundation.Process is macOS-only.
#if os(macOS)
import XCTest
@testable import PomvoxCleanupCloud

private struct Credentials: CredentialProvider {
    func bearerToken() async throws -> String { "test-only-token" }
}

final class CloudDiarizerTests: XCTestCase, @unchecked Sendable {
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

    private func diarizer(_ port: Int, _ path: String) throws -> CloudDiarizer {
        try CloudDiarizer.connect(endpoint: URL(string: "http://127.0.0.1:\(port)/d/\(path)")!,
                                  credentials: Credentials(), pack: RemotePack(id: "diar-test", version: "1.0.0"))
    }

    /// Two seconds of a quiet tone: 32,000 samples, so the WAV the server sees is 2.000 s.
    private let samples: [Float] = (0..<32_000).map { Float(sin(Double($0) * 0.05)) * 0.2 }

    func testSuccessValidatesRelabelsAndReportsClientTimings() async throws {
        let (server, port) = try server()
        defer { stop(server) }
        let remote = try diarizer(port, "ok")
        let result = try await remote.diarize(DiarizationRequest(samples: samples, speakers: 2...2, deadline: .seconds(5)))
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.segments.map(\.speaker.rawValue), ["S1", "S2"]) // server said B then A
        XCTAssertEqual(result.segments.map(\.span.start), [0, 1])
        XCTAssertEqual(result.segments[1].span.end, 2)
        XCTAssertEqual(result.segments[0].confidence, 0.9)
        XCTAssertEqual(result.provenance.route, "cloud")
        XCTAssertEqual(result.provenance.runtime, "loopback-mock")
        XCTAssertEqual(result.timings.budgetMS, 5_000)
        XCTAssertGreaterThan(result.timings.totalMS, 0)
        XCTAssertEqual(result.timings.audioSeconds, 2)
        XCTAssertEqual(result.warnings, ["mock-only"])
        let ready = await remote.availability
        XCTAssertEqual(ready, .ready)
        await remote.close()
    }

    func testUnsortedServerOrderIsAcceptedAndRelabeledByTime() async throws {
        let (server, port) = try server()
        defer { stop(server) }
        let remote = try diarizer(port, "unsorted")
        let result = try await remote.diarize(DiarizationRequest(samples: samples))
        XCTAssertEqual(result.segments.map(\.span.start), [0, 1])
        XCTAssertEqual(result.segments.map(\.speaker.rawValue), ["S1", "S2"])
        await remote.close()
    }

    func testAdversarialResponsesNeverReachTheHost() async throws {
        let (server, port) = try server()
        defer { stop(server) }
        let invalid = ["wrongid", "wrongschema", "wrongpack", "wrongversion", "wrongroute", "emptyruntime", "overrun",
                       "reversed", "negativestart", "badconfidence", "miscount", "toomany", "negative", "missingfield",
                       "truncated", "oversized"]
        for path in invalid + ["http500", "wrongmime", "redirect", "nospeech"] {
            let remote = try diarizer(port, path)
            do {
                _ = try await remote.diarize(DiarizationRequest(samples: samples, deadline: .seconds(5)))
                XCTFail("\(path) must throw")
            } catch let error as DiarizationError {
                switch (path, error) {
                case ("nospeech", .noSpeech): break
                case ("http500", .transport), ("wrongmime", .transport), ("redirect", .transport): break
                case (_, .invalidResponse) where invalid.contains(path): break
                default: XCTFail("\(path): unexpected \(error)")
                }
            }
            await remote.close()
        }
    }

    func testBusyTimeoutCancellationAndClose() async throws {
        let (server, port) = try server()
        defer { stop(server) }
        let slow = try diarizer(port, "slow")
        let start = ContinuousClock.now
        do {
            _ = try await slow.diarize(DiarizationRequest(samples: samples, deadline: .milliseconds(80)))
            XCTFail("must time out")
        } catch DiarizationError.timedOut {}
        XCTAssertLessThan(start.duration(to: .now).milliseconds, 300)
        // The late worker was canceled; once it returns the client is usable again.
        var waited = 0
        while await slow.availability != .ready, waited < 100 { try await Task.sleep(for: .milliseconds(20)); waited += 1 }
        let inFlight = Task { try await slow.diarize(DiarizationRequest(samples: samples, deadline: .seconds(5))) }
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await slow.diarize(DiarizationRequest(samples: samples))
            XCTFail("second request must be refused")
        } catch DiarizationError.busy {}
        _ = try await inFlight.value
        let cancelled = Task { try await slow.diarize(DiarizationRequest(samples: samples, deadline: .seconds(5))) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("must throw") } catch is CancellationError {}
        await slow.close()
        let closed = await slow.availability
        XCTAssertEqual(closed, .closed)
        do { _ = try await slow.diarize(DiarizationRequest(samples: samples)); XCTFail("closed must refuse") }
        catch DiarizationError.unavailable {}
    }

    func testRequestLimitsAndConfigurationAreRefusedBeforeAnyUpload() async throws {
        let remote = try CloudDiarizer.connect(endpoint: URL(string: "http://127.0.0.1:1/d/ok")!,
                                               credentials: Credentials(), pack: RemotePack(id: "diar-test", version: "1.0.0"))
        do {
            _ = try await remote.diarize(DiarizationRequest(audio: .file(URL(fileURLWithPath: "/tmp/a.wav"))))
            XCTFail("files must be refused")
        } catch DiarizationError.invalidRequest {}
        let hour = [Float](repeating: 0, count: Int(CloudDiarizer.maxSeconds) * DiarizationRequest.sampleRate + 1)
        do { _ = try await remote.diarize(DiarizationRequest(samples: hour)); XCTFail("over an hour must be refused") }
        catch DiarizationError.invalidRequest {}
        do { _ = try await remote.diarize(DiarizationRequest(samples: [])); XCTFail("empty must be refused") }
        catch DiarizationError.invalidRequest {}
        await remote.close()
        for endpoint in ["http://example.org/d", "https://user:secret@example.org/d", "https://example.org/d?x=1", "ftp://localhost/d"] {
            XCTAssertThrowsError(try CloudDiarizer.connect(endpoint: URL(string: endpoint)!, credentials: Credentials(),
                                                           pack: RemotePack(id: "diar-test", version: "1.0.0")), endpoint)
        }
        XCTAssertThrowsError(try CloudDiarizer.connect(endpoint: URL(string: "https://example.org/d")!, credentials: Credentials(),
                                                       pack: RemotePack(id: "", version: "1.0.0")))
    }

    func testInvalidCredentialsNeverBecomeHeaders() async throws {
        struct Invalid: CredentialProvider {
            let token: String
            func bearerToken() async throws -> String { token }
        }
        for token in ["", "secret\r\nInjected: value", String(repeating: "x", count: 8_193), "secret\0"] {
            let remote = try CloudDiarizer.connect(endpoint: URL(string: "http://127.0.0.1:1/d/ok")!,
                                                   credentials: Invalid(token: token), pack: RemotePack(id: "diar-test", version: "1.0.0"))
            do { _ = try await remote.diarize(DiarizationRequest(samples: samples)); XCTFail("must throw") }
            catch DiarizationError.unavailable {} // a transport error would mean the credential escaped validation
            await remote.close()
        }
    }

    func testWAVEncodingIsCanonical16kMonoPCM16() {
        let data = WAV.encode16kMono([0, 1, -1, 2, -2, .nan, 0.5])
        XCTAssertEqual(data.count, 44 + 7 * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        func int16(_ index: Int) -> Int16 { Int16(bitPattern: UInt16(data[44 + index * 2]) | UInt16(data[45 + index * 2]) << 8) }
        XCTAssertEqual(int16(0), 0)
        XCTAssertEqual(int16(1), 32_767)
        XCTAssertEqual(int16(2), -32_767)
        XCTAssertEqual(int16(3), 32_767) // clamped
        XCTAssertEqual(int16(4), -32_767)
        XCTAssertEqual(int16(5), 0) // NaN becomes silence
        XCTAssertEqual(int16(6), 16_384)
        let rate = UInt32(data[24]) | UInt32(data[25]) << 8 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24
        XCTAssertEqual(rate, 16_000)
    }
}
#endif
