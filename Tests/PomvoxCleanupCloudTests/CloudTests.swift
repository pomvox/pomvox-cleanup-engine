import XCTest
@testable import PomvoxCleanupCloud

private struct Credentials: CredentialProvider {
    func bearerToken() async throws -> String { "test-only-token" }
}

private struct SlowCredentials: CredentialProvider {
    func bearerToken() async throws -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                continuation.resume(returning: "test-only-token")
            }
        }
    }
}

final class CloudTests: XCTestCase, @unchecked Sendable {
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
    private func request(_ deadline: Duration = .seconds(2)) -> CleanupRequest {
        CleanupRequest("😀 hello", vocabulary: ["Pomvox"], context: "explicit test context",
                       settings: ["style": "test"], deadline: deadline)
    }

    func testExplicitPayloadResponsesFailuresAndRedirectRefusal() async throws {
        let (server, port) = try server()
        defer { server.terminate(); server.waitUntilExit() }
        for (path, status) in [("clean", CleanupStatus.unchanged), ("edit", .cleaned),
            ("invalid", .fallback(.invalidResponse)), ("wrongpack", .fallback(.invalidResponse)),
            ("oversized", .fallback(.invalidResponse)), ("redirect", .fallback(.transport))] {
            let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:\(port)/\(path)")!,
                credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0"))
            let result = try await cleaner.clean(request())
            XCTAssertEqual(result.status, status, path)
            if case .fallback = status { XCTAssertEqual(result.text, request().text) }
            else {
                XCTAssertEqual(result.timings.serverInferenceMS, 3)
                XCTAssertEqual(try TextEdit.applying(result.edits, to: request().text), result.text)
            }
            await cleaner.close()
        }
    }

    func testTransportDeadlineAndCancellation() async throws {
        let (server, port) = try server()
        defer { server.terminate(); server.waitUntilExit() }
        let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:\(port)/slow")!,
            credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0"))
        let start = ContinuousClock.now
        let result = try await cleaner.clean(request(.milliseconds(80)))
        XCTAssertEqual(result.status, .fallback(.timedOut))
        XCTAssertLessThan(start.duration(to: .now).milliseconds, 300)
        await cleaner.close()
        let cancelCleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:\(port)/slow")!,
            credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0"))
        let task = Task { try await cancelCleaner.clean(request()) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("must throw") } catch is CancellationError {}
        await cancelCleaner.close()
    }

    func testUncooperativeCredentialsAreInsideDeadlineAndBounded() async throws {
        let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:1/clean")!,
            credentials: SlowCredentials(), pack: RemotePack(id: "test", version: "1.0.0"))
        let start = ContinuousClock.now
        let result = try await cleaner.clean(request(.milliseconds(50)))
        XCTAssertEqual(result.status, .fallback(.timedOut))
        XCTAssertLessThan(start.duration(to: .now).milliseconds, 250)
        let busy = try await cleaner.clean(request())
        XCTAssertEqual(busy.status, .fallback(.busy))
        await cleaner.close()
    }

    func testEmptyInputDoesNotRetrieveCredentialsOrContactEndpoint() async throws {
        let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:1/clean")!,
            credentials: SlowCredentials(), pack: RemotePack(id: "test", version: "1.0.0"))
        let result = try await cleaner.clean("")
        XCTAssertEqual(result.status, .unchanged)
        XCTAssertLessThan(result.timings.totalMS, 100)
        XCTAssertEqual(result.warnings, ["empty-input-no-remote-execution"])
        await cleaner.close()
    }

    func testRejectsUnsafeConfiguration() throws {
        XCTAssertThrowsError(try CloudCleaner.connect(endpoint: URL(string: "http://example.org/clean")!,
            credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0")))
        XCTAssertThrowsError(try CloudCleaner.connect(endpoint: URL(string: "https://user:secret@example.org/clean")!,
            credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0")))
    }
}


extension CloudTests {
    func testAdversarialResponseMatrixPreservesExactInput() async throws {
        let (server, port) = try server()
        defer { server.terminate(); server.waitUntilExit() }
        let invalid = ["wrongid", "wrongschema", "wrongversion", "wrongroute", "emptydigest", "emptyruntime",
                       "negative", "unknownstatus", "cleanedwithoutedit", "unchangedwithchange", "fallbackwithchange",
                       "overlap", "manyedits", "hugeresult", "missingfield", "truncated", "invalidutf8", "overflow"]
        for path in invalid + ["http500", "wrongmime", "fallback"] {
            let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:\(port)/\(path)")!,
                credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0"))
            let result = try await cleaner.clean(request())
            let reason: FallbackReason = path == "fallback" ? .rejected
                : (["http500", "wrongmime"].contains(path) ? .transport : .invalidResponse)
            XCTAssertEqual(result.status, .fallback(reason), path)
            XCTAssertEqual(Array(result.text.utf8), Array(request().text.utf8), path)
            XCTAssertTrue(result.edits.isEmpty, path)
            XCTAssertTrue(result.timings.isValid, path)
            XCTAssertNoThrow(try JSONEncoder().encode(result))
            await cleaner.close()
        }
    }

    func testBodyStreamingIsInsideDeadline() async throws {
        let (server, port) = try server()
        defer { server.terminate(); server.waitUntilExit() }
        let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:\(port)/slowbody")!,
            credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0"))
        let start = ContinuousClock.now
        let result = try await cleaner.clean(request(.milliseconds(80)))
        XCTAssertEqual(result.status, .fallback(.timedOut))
        XCTAssertLessThan(start.duration(to: .now).milliseconds, 350)
        await cleaner.close()
    }

    func testEndpointValidationMatrixAndClosedLifecycle() async throws {
        for endpoint in ["ftp://localhost/clean", "http://example.org/clean", "https://example.org/clean?token=x",
                         "https://example.org/clean#fragment", "https://user@example.org/clean"] {
            XCTAssertThrowsError(try CloudCleaner.connect(endpoint: URL(string: endpoint)!,
                credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0")))
        }
        for pack in [RemotePack(id: "", version: "1"), RemotePack(id: "test", version: ""),
                     RemotePack(id: String(repeating: "a", count: 65), version: "1")] {
            XCTAssertThrowsError(try CloudCleaner.connect(endpoint: URL(string: "https://example.org/clean")!,
                credentials: Credentials(), pack: pack))
        }
        let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:1/clean")!,
            credentials: Credentials(), pack: RemotePack(id: "test", version: "1.0.0"))
        await cleaner.close(); await cleaner.close()
        let closed = try await cleaner.clean(request())
        XCTAssertEqual(closed.status, .fallback(.unavailable))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cleaner.clean(request())
        }
        do { _ = try await cancelled.value; XCTFail("must throw") } catch is CancellationError {}
    }

    func testInvalidCredentialsNeverBecomeHTTPHeaders() async throws {
        struct InvalidCredentials: CredentialProvider {
            let token: String
            func bearerToken() async throws -> String { token }
        }
        for token in ["", "secret\r\nInjected: value", String(repeating: "x", count: 8193), "secret\0"] {
            let cleaner = try CloudCleaner.connect(endpoint: URL(string: "http://127.0.0.1:1/clean")!,
                credentials: InvalidCredentials(token: token), pack: RemotePack(id: "test", version: "1.0.0"))
            let result = try await cleaner.clean(request())
            // A transport error would mean the invalid credential escaped validation.
            XCTAssertEqual(result.status, .fallback(.invalidResponse))
            await cleaner.close()
        }
    }
}
