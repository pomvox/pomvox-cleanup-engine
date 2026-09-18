import Foundation
import PomvoxCleanupMLX

@main
struct Consumer {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: Consumer /absolute/path/to/installed-pack [transcript | --benchmark]")
            return
        }
        let cleaner = try await Cleaner.open(pack: .directory(URL(fileURLWithPath: CommandLine.arguments[1])),
                                             runtime: .mlx, policy: .local)
        let benchmark = CommandLine.arguments.dropFirst(2).contains("--benchmark")
        let raw = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "um hello there"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if benchmark {
                // Public synthetic smoke workload, not a quality evaluation or production SLO.
                let fixtures = ["um hello there", "let's meet on tuesday wait no friday at noon",
                    "number one review the report number two update the draft number three send it on friday"]
                var runs: [BenchmarkRun] = []
                for repeatIndex in 0..<5 {
                    for (fixture, text) in fixtures.enumerated() {
                        let result = try await cleaner.clean(CleanupRequest(text, deadline: .seconds(30)))
                        runs.append(BenchmarkRun(fixture: fixture, repeatIndex: repeatIndex,
                            inputBytes: text.utf8.count, outputBytes: result.text.utf8.count,
                            status: result.status, timings: result.timings))
                    }
                }
                print(String(decoding: try encoder.encode(runs), as: UTF8.self))
            } else {
                let result = try await cleaner.clean(CleanupRequest(raw, deadline: .seconds(30)))
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            }
            await cleaner.close()
        } catch { await cleaner.close(); throw error }
    }
}

private struct BenchmarkRun: Codable {
    let fixture: Int
    let repeatIndex: Int
    let inputBytes: Int
    let outputBytes: Int
    let status: CleanupStatus
    let timings: CleanupTimings
}
