import XCTest
@testable import PomvoxCleanupMLX

final class ModelDifferentialTests: XCTestCase {
    static let transcripts: [String] = [
        "let's meet on tuesday wait no friday at noon",
        "so there are four options wait no five options to consider",
        "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually.",
        "Let's schedule a meeting for this Thursday. No, no, no. Friday at noon.",
        "Let's do uh a shopping list. Uh we'll get bananas, apples and mangoes."
            + " No, no, oranges.",
        "Hi, how are you doing? Can we meet on Friday? Or actually, let's do"
            + " Thursday, not Friday.",
        "um so i think we should uh probably ship it tomorrow",
        "okay so basically what happened was we went to the meeting and then uh the "
            + "client said they wanted changes and um so we're gonna have to redo the whole "
            + "thing by friday i think",
        "we sold uh like twenty five hundred units last month up from um two thousand",
        "The meeting is confirmed for Tuesday at 3 PM in the main conference room.",
        "let's make a list of things to pack shirts socks toothbrush and a charger",
        "i i i just wanted to to say that that the the report is is ready",
        "go ahead",
        "so um i wanted to walk you through the plan uh first we do the research then um we build a prototype and uh after that we test it with users and finally ship it",
        "please review the report tomorrow morning and send the updated draft to the team before lunch actually make that before the afternoon meeting",
        "do not delete the backup and do not restart the server until i confirm",
        "the invoice is for twelve dollars and fifty cents not fifteen dollars",
        "send the report to zoë and josé at café central tomorrow",
        "the file is called config dot json and the variable is user underscore id",
        "hello 👩🏽‍💻 the meeting is at café central",
        "please keep the original wording exactly as it is",
        "my email is alex at example dot com and the ticket number is four two zero",
        "the temperature was minus five degrees yesterday and plus three today",
        "number one fix the login bug number two update the docs number three ship it on friday",
    ]


    func testRealArtifactDifferential() async throws {
        guard let path = ProcessInfo.processInfo.environment["POMVOX_TEST_PACK"] else {
            throw XCTSkip("set POMVOX_TEST_PACK to an installed verified pack; never downloads")
        }
        let pack = try PackLoader.validate(directory: URL(fileURLWithPath: path))
        var reference: [String] = []
        let legacy = LegacyReference()
        try await legacy.prepare(directory: pack.directory, cached: true)
        for raw in Self.transcripts {
            let out = try await legacy.clean(raw, style: "polish", timeoutS: 60)
            reference.append(try XCTUnwrap(out))
        }
        await legacy.unload()
        for (mode, disabled) in [(Decoding.library, false), (.greedy, false), (.speculative, false), (.speculative, true)] {
            let runtime = try await MLXRuntime.open(pack: pack, mode: mode, prefixDisabled: disabled)
            do {
                _ = try await MLXRuntime.open(pack: pack)
                XCTFail("a second resident allocation must be refused")
            } catch CleanupError.unavailable {} // Existing worker/model remains intact.
            let hasPrefix = await runtime.hasPrefix
            XCTAssertEqual(hasPrefix, !disabled)
            var accepted = 0
            var elapsed: [Double] = []
            for (index, raw) in Self.transcripts.enumerated() {
                let start = ContinuousClock.now
                let out = try await runtime.generate(CleanupRequest(raw), deadline: .now.advanced(by: .seconds(60)))
                elapsed.append(start.duration(to: .now).milliseconds)
                XCTAssertTrue(out.timings.isValid)
                let candidate = try XCTUnwrap(out.candidate)
                XCTAssertEqual(Array(candidate.utf8), Array(reference[index].utf8), "fixture \(index), mode \(mode), uncached \(disabled)")
                XCTAssertEqual(CleanupLogic.acceptOutput(raw: raw, cleaned: candidate),
                               CleanupLogic.acceptOutput(raw: raw, cleaned: reference[index]))
                let stats = await runtime.lastStats
                accepted += stats?.specAccepted ?? 0
            }
            if mode == .speculative { XCTAssertGreaterThan(accepted, 0) }
            // Different vocabulary must never poison the reusable static prefix.
            let raw = "um hello there"
            let before = try await runtime.generate(CleanupRequest(raw), deadline: .now.advanced(by: .seconds(30)))
            _ = try await runtime.generate(CleanupRequest(raw, vocabulary: ["Pomvox"]), deadline: .now.advanced(by: .seconds(30)))
            let after = try await runtime.generate(CleanupRequest(raw), deadline: .now.advanced(by: .seconds(30)))
            XCTAssertEqual(before.candidate, after.candidate)
            print("DIFFERENTIAL mode=\(mode) uncached=\(disabled) fixtures=\(elapsed.count) medianMS=\(elapsed.sorted()[elapsed.count / 2]) acceptedDrafts=\(accepted)")
            let expired = try await runtime.generate(CleanupRequest(raw), deadline: .now.advanced(by: .seconds(-1)))
            XCTAssertEqual(expired.failure, .timedOut)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await runtime.generate(CleanupRequest(raw), deadline: .now.advanced(by: .seconds(30)))
            }
            do { _ = try await cancelled.value; XCTFail("pre-cancelled runtime request must throw") }
            catch is CancellationError {}
            await runtime.close()
            await runtime.close()
            let closed = try await runtime.generate(CleanupRequest(raw), deadline: .now.advanced(by: .seconds(30)))
            XCTAssertEqual(closed.failure, .unavailable)
        }
    }
}


extension ModelDifferentialTests {
    func testVocabularyPrefixParityAndReuse() async throws {
        guard let path = ProcessInfo.processInfo.environment["POMVOX_TEST_PACK"] else {
            throw XCTSkip("set POMVOX_TEST_PACK; never downloads")
        }
        let pack = try PackLoader.validate(directory: URL(fileURLWithPath: path))
        let dictionaries = [["Pomvox"], ["Pomvox", "Abhi"], [], ["Pomvox"],
            (0..<64).map { "Term\($0)" }, ["Caf\u{00e9}"], ["Cafe\u{0301}"], ["Caf\u{00e9}"]]
        var reference: [String] = []
        for disabled in [true, false] {
            let runtime = try await MLXRuntime.open(pack: pack, prefixDisabled: disabled, vocabulary: dictionaries[0])
            do {
                for (index, dictionary) in dictionaries.enumerated() {
                    for repetition in 0..<2 {
                        let output = try await runtime.generate(CleanupRequest(
                            "um please send the pomvox report to abhi tomorrow", vocabulary: dictionary),
                            deadline: .now.advanced(by: .seconds(60)))
                        let candidate = try XCTUnwrap(output.candidate)
                        XCTAssertEqual(output.timings.prefixCacheUsed, !disabled)
                        if disabled { reference.append(candidate) }
                        else { XCTAssertEqual(Array(candidate.utf8), Array(reference[index * 2 + repetition].utf8)) }
                    }
                }
                await runtime.close()
            } catch { await runtime.close(); throw error }
        }
    }
}
