import CleanupNotes
import FluidAudio
import Foundation
import PomvoxCleanupCloud
import PomvoxCleanupMLX
import PomvoxDiarizationFluid

// A local companion process for a browser page: the engine's own wire protocols
// (cleanup v1, diarization v1) served on loopback over the real local runtimes,
// plus one convenience endpoint that runs the whole speaker-notes pipeline so a
// web page can try it. Host stand-in, like the other examples: the SDK owns no
// STT, no server and no UI. Parakeet runs here through FluidAudio only to get
// word timings for the demo.
//
// Usage:
//   LocalServer <installed-cleanup-pack> <installed-diarizer-pack> [--port 8787] [--web <dir>]
//               [--asr-models <dir>] [--no-stt] [--token <secret>]

enum ServerError: Error, CustomStringConvertible {
    case usage, invalidWAV(String)
    var description: String {
        switch self {
        case .usage: return "usage: LocalServer <cleanup-pack> <diarizer-pack> [--port 8787] [--web <dir>] [--asr-models <dir>] [--no-stt] [--token <secret>]"
        case .invalidWAV(let detail): return "invalid WAV: \(detail)"
        }
    }
}

/// Minimal RIFF/WAVE reader: PCM 8/16/24/32-bit or float32, any channel count
/// (averaged to mono), any rate (linear resample to 16 kHz when needed).
enum WAVReader {
    static func samples16kMono(_ data: Data) throws -> [Float] {
        guard data.count >= 44, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw ServerError.invalidWAV("not a RIFF/WAVE file")
        }
        var offset = 12
        var format: (tag: UInt16, channels: Int, rate: Int, bits: Int)?
        var pcm: Data?
        func u16(_ at: Int) -> UInt16 { data[at..<at + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            let start = offset + 8
            guard start + size <= data.count || id == "data" else { throw ServerError.invalidWAV("truncated chunk \(id)") }
            if id == "fmt " {
                format = (u16(start), Int(u16(start + 2)), Int(u32(start + 4)), Int(u16(start + 14)))
            } else if id == "data" {
                pcm = data[start..<min(data.count, start + size)]
            }
            offset = start + size + (size % 2)
        }
        guard let format, let pcm else { throw ServerError.invalidWAV("missing fmt or data chunk") }
        guard format.channels >= 1, format.rate >= 8_000 else { throw ServerError.invalidWAV("unsupported format") }
        let bytesPerSample = format.bits / 8
        let frameBytes = bytesPerSample * format.channels
        guard frameBytes > 0 else { throw ServerError.invalidWAV("zero-size frames") }
        let frames = pcm.count / frameBytes
        var mono = [Float](repeating: 0, count: frames)
        pcm.withUnsafeBytes { raw in
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<format.channels {
                    let at = frame * frameBytes + channel * bytesPerSample
                    let value: Float
                    switch (format.tag, format.bits) {
                    case (3, 32): value = raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                    case (1, 16): value = Float(raw.loadUnaligned(fromByteOffset: at, as: Int16.self)) / 32_768
                    case (1, 8): value = (Float(raw[at]) - 128) / 128
                    case (1, 24):
                        let v = Int32(raw[at]) | Int32(raw[at + 1]) << 8 | Int32(Int8(bitPattern: raw[at + 2])) << 16
                        value = Float(v) / 8_388_608
                    case (1, 32): value = Float(raw.loadUnaligned(fromByteOffset: at, as: Int32.self)) / 2_147_483_648
                    default: value = 0
                    }
                    sum += value
                }
                mono[frame] = sum / Float(format.channels)
            }
        }
        if format.rate == 16_000 { return mono }
        let ratio = Double(format.rate) / 16_000
        let count = Int(Double(frames) / ratio)
        return (0..<count).map { index in
            let position = Double(index) * ratio
            let lower = Int(position), upper = min(lower + 1, frames - 1)
            let fraction = Float(position - Double(lower))
            return mono[lower] * (1 - fraction) + mono[upper] * fraction
        }
    }
}

/// Parakeet token timings to words, as in the speaker-notes example.
func words(from timings: [TokenTiming]) -> [TimedWord] {
    var words: [TimedWord] = []
    var text = "", start: TimeInterval = 0, end: TimeInterval = 0, open = false
    func flush() {
        if open, !text.isEmpty { words.append(TimedWord(text, span: TimeSpan(start: start, end: end))) }
        open = false
    }
    for timing in timings {
        let piece = timing.token
        let startsWord = piece.hasPrefix(" ") || piece.hasPrefix("▁")
        let fragment = piece.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "▁", with: "")
        if startsWord || !open {
            flush(); text = fragment; start = timing.startTime; end = timing.endTime; open = true
        } else {
            text += fragment; end = max(end, timing.endTime)
        }
    }
    flush()
    return words
}

struct Envelope<Result: Encodable>: Encodable {
    let schemaVersion = 1
    let requestID: UUID
    let result: Result
}

struct Status: Encodable {
    let cleanupPack: String, cleanupPackVersion: String, cleanupRuntime: String
    let diarizerPack: String, diarizerPackVersion: String, diarizerRuntime: String
    let speechRecognition: String
    let protocols: [String]
}

struct SpeakerNotesReply: Encodable {
    struct Stage: Encodable { let sttMS: Double, diarizationMS: Double, cleanupMS: Double, totalMS: Double }
    let words: Int
    let segmentation: SpeakerSegmentation
    let transcript: TranscriptResult
    let notes: Notes
    let markdown: String
    let stages: Stage
}

/// Serializes access to the three runtimes and restamps provenance for the wire.
actor Engine {
    let cleaner: Cleaner
    let diarizer: FluidDiarizer
    let asr: AsrManager?
    private var decoderLayers = 2

    init(cleaner: Cleaner, diarizer: FluidDiarizer, asr: AsrManager?) {
        self.cleaner = cleaner; self.diarizer = diarizer; self.asr = asr
    }

    func prepareSTT() async {
        if let asr { decoderLayers = await asr.decoderLayerCount }
    }

    /// A served result carries route `cloud` and names this server, as a real service would.
    func wire(_ provenance: Provenance) -> Provenance {
        Provenance(packID: provenance.packID, packVersion: provenance.packVersion, artifactDigest: provenance.artifactDigest,
                   modelRevision: provenance.modelRevision, runtime: "pomvox-local-server/" + provenance.runtime,
                   route: "cloud", settings: provenance.settings)
    }

    func clean(_ request: CloudRequest) async throws -> CleanupResult {
        let deadline = Duration.milliseconds(min(60_000, max(1, request.remainingMilliseconds)))
        let result = try await cleaner.clean(CleanupRequest(request.text, vocabulary: request.vocabulary, context: request.context,
                                                             settings: request.settings, deadline: deadline))
        return CleanupResult(text: result.text, edits: result.edits, status: result.status, provenance: wire(result.provenance),
                             timings: result.timings, warnings: result.warnings)
    }

    func diarize(_ samples: [Float], speakers: ClosedRange<Int>?, deadline: Duration?) async throws -> SpeakerSegmentation {
        let result = try await diarizer.diarize(DiarizationRequest(samples: samples, speakers: speakers, deadline: deadline))
        return SpeakerSegmentation(segments: result.segments, speakerCount: result.speakerCount, provenance: wire(result.provenance),
                                   timings: result.timings, warnings: result.warnings)
    }

    func speakerNotes(_ samples: [Float], speakers: ClosedRange<Int>?) async throws -> SpeakerNotesReply {
        guard let asr else { throw DiarizationError.unavailable("speech recognition is not loaded (--no-stt)") }
        let started = ContinuousClock.now
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let recognized = try await asr.transcribe(samples, decoderState: &state)
        let recognizedWords = words(from: recognized.tokenTimings ?? [])
        let sttMS = started.duration(to: .now).milliseconds
        let diarizeStart = ContinuousClock.now
        let segmentation = try await diarizer.diarize(DiarizationRequest(samples: samples, speakers: speakers, deadline: .seconds(300)))
        let diarizationMS = diarizeStart.duration(to: .now).milliseconds
        let transcript = Transcript.attribute(words: recognizedWords, segments: segmentation.segments)
        let cleanStart = ContinuousClock.now
        let cleaned = try await cleaner.clean(transcript, options: TranscriptCleanOptions(
            transforms: [.spokenLayout], turnBudget: .measuredM1, overallDeadline: .seconds(180)))
        let cleanupMS = cleanStart.duration(to: .now).milliseconds
        let notes = Notes.extract(from: cleaned)
        let markdown = NotesRenderer.markdown(notes, options: NotesRenderer.Options(title: "Speaker notes", includeTimestamps: true))
        return SpeakerNotesReply(words: recognizedWords.count, segmentation: segmentation, transcript: cleaned, notes: notes,
                                 markdown: markdown, stages: .init(sttMS: sttMS, diarizationMS: diarizationMS, cleanupMS: cleanupMS,
                                                                   totalMS: started.duration(to: .now).milliseconds))
    }
}

func parseSpeakers(_ header: String?) -> ClosedRange<Int>? {
    guard let header else { return nil }
    let parts = header.split(separator: "-").compactMap { Int($0) }
    guard let first = parts.first, let last = parts.last, first <= last else { return nil }
    return first...last
}

func main() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var port: UInt16 = 8787, web: String?, asrPath: String?, stt = true, token: String?
    var positional: [String] = []
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--port": port = UInt16(arguments.removeFirst()) ?? 8787
        case "--web": web = arguments.removeFirst()
        case "--asr-models": asrPath = arguments.removeFirst()
        case "--no-stt": stt = false
        case "--token": token = arguments.removeFirst()
        default: positional.append(argument)
        }
    }
    guard positional.count == 2 else { throw ServerError.usage }
    let webDirectory = URL(fileURLWithPath: web ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web").path)
    let secret = token ?? (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    let log = { (line: String) in FileHandle.standardError.write(Data((line + "\n").utf8)) }

    log("opening cleanup pack \(positional[0]) …")
    let cleaner = try await Cleaner.open(pack: .directory(URL(fileURLWithPath: positional[0])), runtime: .mlx, policy: .local)
    log("cleanup ready in \(Int(cleaner.preparationMS)) ms: \(cleaner.pack.manifest.id) \(cleaner.pack.manifest.version)")
    let diarizerPack = try DiarizerPackLoader.validate(directory: URL(fileURLWithPath: positional[1]))
    let diarizer = try await FluidDiarizer.open(pack: diarizerPack)   // from here on FluidAudio never downloads
    log("diarizer ready in \(Int(diarizer.preparationMS)) ms: \(diarizerPack.manifest.id) \(diarizerPack.manifest.version)")
    var asr: AsrManager?
    if stt {
        let directory = asrPath.map { URL(fileURLWithPath: $0) } ?? AsrModels.defaultCacheDirectory(for: .v3)
        do {
            let models = try await AsrModels.load(from: directory, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
            log("speech recognition ready (Parakeet TDT v3 from \(directory.path); example host stand-in)")
        } catch {
            log("speech recognition unavailable (\(error)); /v1/speaker-notes will answer 503. Pass --asr-models or --no-stt.")
        }
    }
    let engine = Engine(cleaner: cleaner, diarizer: diarizer, asr: asr)
    await engine.prepareSTT()
    let status = Status(cleanupPack: cleaner.pack.manifest.id, cleanupPackVersion: cleaner.pack.manifest.version,
                        cleanupRuntime: "pomvox-local-server/" + cleaner.pack.manifest.runtime,
                        diarizerPack: diarizerPack.manifest.id, diarizerPackVersion: diarizerPack.manifest.version,
                        diarizerRuntime: FluidDiarizer.runtimeName,
                        speechRecognition: asr == nil ? "not loaded" : "parakeet-tdt-0.6b-v3 via FluidAudio (example only)",
                        protocols: ["cleanup/1 POST /v1/clean", "diarization/1 POST /v1/diarize", "demo POST /v1/speaker-notes"])

    let server = try HTTPServer(port: port, maxBody: 130_000_000) { request in
        func authorized() -> Bool { request.header("authorization") == "Bearer \(secret)" }
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            guard let page = try? String(contentsOf: webDirectory.appendingPathComponent("index.html"), encoding: .utf8) else {
                return .error(404, "web directory not found; pass --web")
            }
            return .text(page.replacingOccurrences(of: "__TOKEN__", with: secret), type: "text/html; charset=utf-8")
        case ("GET", "/app.js"), ("GET", "/style.css"):
            guard let file = try? Data(contentsOf: webDirectory.appendingPathComponent(String(request.path.dropFirst()))) else { return .error(404, "missing") }
            return HTTPResponse(status: 200, headers: ["Content-Type": request.path.hasSuffix(".js") ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8"], body: file)
        case ("GET", "/v1/status"):
            return .json(status)
        case ("POST", "/v1/clean"):
            guard authorized() else { return .error(401, "bearer token required") }
            guard request.header("content-type")?.hasPrefix("application/json") == true,
                  let wire = try? JSONDecoder().decode(CloudRequest.self, from: request.body) else { return .error(400, "cleanup protocol v1 JSON required") }
            guard wire.schemaVersion == 1 else { return .error(400, "schemaVersion must be 1") }
            guard wire.pack.id == status.cleanupPack, wire.pack.version == status.cleanupPackVersion else {
                return .error(400, "this server serves pack \(status.cleanupPack) \(status.cleanupPackVersion)")
            }
            guard UUID(uuidString: request.header("idempotency-key") ?? "") == wire.requestID else { return .error(400, "Idempotency-Key must equal requestID") }
            do { return .json(Envelope(requestID: wire.requestID, result: try await engine.clean(wire))) }
            catch let error as CleanupError { return .error(400, error.localizedDescription) }
            catch { return .error(500, String(describing: error)) }
        case ("POST", "/v1/diarize"), ("POST", "/v1/speaker-notes"):
            guard authorized() else { return .error(401, "bearer token required") }
            guard request.header("content-type")?.hasPrefix("audio/wav") == true else { return .error(415, "audio/wav body required") }
            let samples: [Float]
            do { samples = try WAVReader.samples16kMono(request.body) } catch { return .error(400, String(describing: error)) }
            let speakers = parseSpeakers(request.header("x-pomvox-speakers"))
            do {
                if request.path == "/v1/diarize" {
                    guard request.header("x-pomvox-schema") == "1" else { return .error(400, "X-Pomvox-Schema: 1 required") }
                    guard request.header("x-pomvox-pack") == status.diarizerPack,
                          request.header("x-pomvox-pack-version") == status.diarizerPackVersion else {
                        return .error(400, "this server serves pack \(status.diarizerPack) \(status.diarizerPackVersion)")
                    }
                    guard let key = request.header("idempotency-key"), let id = UUID(uuidString: key) else { return .error(400, "Idempotency-Key UUID required") }
                    let remaining = Int(request.header("x-pomvox-remaining-milliseconds") ?? "") ?? 300_000
                    let result = try await engine.diarize(samples, speakers: speakers, deadline: .milliseconds(min(3_600_000, max(1, remaining))))
                    return .json(Envelope(requestID: id, result: result))
                }
                return .json(try await engine.speakerNotes(samples, speakers: speakers))
            } catch DiarizationError.busy { return .error(429, "a request is already running") }
            catch DiarizationError.timedOut { return .error(504, "deadline passed") }
            catch DiarizationError.noSpeech { return .error(400, "no speech detected") }
            catch let error as DiarizationError { return .error(error.localizedDescription.contains("not loaded") ? 503 : 400, error.localizedDescription) }
            catch { return .error(500, String(describing: error)) }
        case ("POST", "/v1/notes"):
            return .error(501, "model-written notes need a model behind the endpoint; this example server has none. Notes.extract runs client-side in the page.")
        case (_, let path) where path.hasPrefix("/v1/"):
            return .error(request.method == "GET" || request.method == "POST" ? 404 : 405, "unknown endpoint")
        default:
            return .error(404, "not found")
        }
    }
    let bound = try await server.start()
    print("Pomvox local server on http://127.0.0.1:\(bound)/  (loopback only)")
    print("token: \(secret)")
    print("protocols: cleanup v1 at /v1/clean, diarization v1 at /v1/diarize, demo at /v1/speaker-notes; status at /v1/status")
    fflush(stdout)
    while true { try await Task.sleep(for: .seconds(3_600)) }
}

do { try await main() } catch {
    FileHandle.standardError.write(Data("LocalServer: \(error)\n".utf8))
    exit(1)
}
