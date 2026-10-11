import PomvoxNotes
import FluidAudio
import Foundation
import PomvoxDiarizationFluid

/// Host stand-in, not SDK: shows the speaker-notes pipeline end to end on one
/// audio file. Speech recognition runs here through FluidAudio's Parakeet (as
/// the Pomvox app does on its side) only to obtain word timings; the SDK owns
/// no STT. Cleanup is not run: the MLX runtime needs an Xcode build to package
/// Metal shaders, so the transcript is rendered as recognized, marked as such.
@main
struct SpeakerNotesExample {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("speaker-notes-example: \(error)\n".utf8))
            exit(1)
        }
    }

    static func usage() -> Never {
        print("""
        Usage: speaker-notes-example <audio-file> --diarizer-pack <installed-pack> [options]
          --asr-models <dir>     Parakeet TDT v3 Core ML bundles already on disk
                                 (default: FluidAudio's cache for parakeet-tdt-0.6b-v3). Never downloads.
          --speakers N | MIN-MAX Expected speaker count or bounds.
          --threshold 0.6        Clustering threshold (community-1 default 0.6; lower finds more speakers).
          --min-segment 1.0      Shortest speech stretch that gets a speaker embedding, seconds.
          --compute-units all|cpuAndNeuralEngine|cpuAndGPU|cpuOnly
          --names S1=Abhi,S2=Sam Display names per label.
          --no-stt               Skip speech recognition; print the segmentation only.
          --segments-json        Also print the speaker segmentation as JSON on stderr.
        """)
        exit(2)
    }

    static func run(_ arguments: [String]) async throws {
        var audio: URL?, packPath: String?, asrPath: String?, speakers: ClosedRange<Int>?
        var names: [SpeakerLabel: String] = [:], dumpSegments = false, skipSTT = false
        var config = FluidDiarizerConfig()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--diarizer-pack": packPath = iterator.next()
            case "--asr-models": asrPath = iterator.next()
            case "--speakers":
                guard let value = iterator.next() else { usage() }
                let parts = value.split(separator: "-").compactMap { Int($0) }
                guard let first = parts.first, let last = parts.last, first <= last else { usage() }
                speakers = first...last
            case "--names":
                for pair in (iterator.next() ?? "").split(separator: ",") {
                    let sides = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard sides.count == 2 else { usage() }
                    names[SpeakerLabel(sides[0])] = sides[1]
                }
            case "--segments-json": dumpSegments = true
            case "--no-stt": skipSTT = true
            case "--threshold":
                guard let value = iterator.next(), let threshold = Double(value) else { usage() }
                config.clusteringThreshold = threshold
            case "--min-segment":
                guard let value = iterator.next(), let seconds = Double(value) else { usage() }
                config.minSegmentSeconds = seconds
            case "--compute-units":
                switch iterator.next() {
                case "all": config.computeUnits = .all
                case "cpuAndNeuralEngine": config.computeUnits = .cpuAndNeuralEngine
                case "cpuAndGPU": config.computeUnits = .cpuAndGPU
                case "cpuOnly": config.computeUnits = .cpuOnly
                default: usage()
                }
            case "-h", "--help": usage()
            default:
                guard audio == nil, !argument.hasPrefix("-") else { usage() }
                audio = URL(fileURLWithPath: argument)
            }
        }
        guard let audio, let packPath else { usage() }
        let stderr = FileHandle.standardError
        func log(_ line: String) { stderr.write(Data((line + "\n").utf8)) }

        // 1. Verified diarizer pack, opened offline. From here on FluidAudio may not download.
        let pack = try DiarizerPackLoader.validate(directory: URL(fileURLWithPath: packPath))
        let diarizer = try await FluidDiarizer.open(pack: pack, config: config)
        defer { Task { await diarizer.close() } }
        log("diarizer: \(pack.manifest.id) \(pack.manifest.version) ready in \(Int(diarizer.preparationMS)) ms")

        // 2. The host's audio, as 16 kHz mono samples.
        let samples = try AudioConverter().resampleAudioFile(audio)
        log("audio: \(String(format: "%.1f", Double(samples.count) / 16_000)) s")

        // 3. Who spoke when.
        let segmentation = try await diarizer.diarize(DiarizationRequest(samples: samples, speakers: speakers))
        log("diarization: \(segmentation.speakerCount) speakers, \(segmentation.segments.count) segments, "
            + "\(Int(segmentation.timings.totalMS)) ms (segmentation \(Int(segmentation.timings.segmentationMS ?? -1)), "
            + "embedding \(Int(segmentation.timings.embeddingMS ?? -1)), clustering \(Int(segmentation.timings.clusteringMS ?? -1)))")
        if dumpSegments {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            log(String(decoding: try encoder.encode(segmentation), as: UTF8.self))
        }

        if skipSTT {
            for segment in segmentation.segments {
                print("\(segment.speaker.rawValue)\t\(String(format: "%.2f", segment.span.start))\t\(String(format: "%.2f", segment.span.end))")
            }
            await diarizer.close()
            return
        }

        // 4. Host-side STT with word timings (Parakeet via FluidAudio, already on disk).
        let asrDirectory = asrPath.map { URL(fileURLWithPath: $0) } ?? AsrModels.defaultCacheDirectory(for: .v3)
        let models = try await AsrModels.load(from: asrDirectory, version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let recognized = try await asr.transcribe(samples, decoderState: &state)
        let words = Self.words(from: recognized.tokenTimings ?? [])
        log("stt: \(words.count) words, \(String(format: "%.2f", recognized.confidence)) confidence")

        // 5. Pure alignment, then notes. Cleanup is deliberately not run here.
        let transcript = Transcript.attribute(words: words, segments: segmentation.segments)
        let uncleaned = TranscriptResult(turns: transcript.turns.map {
            TurnResult(turn: $0, result: CleanupResult(text: $0.text, edits: [], status: .unchanged,
                                                       provenance: .skipped, warnings: ["example-not-cleaned"]))
        }, elapsedMS: 0)
        let notes = Notes.extract(from: uncleaned)
        print(NotesRenderer.markdown(notes, options: NotesRenderer.Options(
            title: "Speaker notes (recognized text, not cleaned)", speakerNames: names, includeTimestamps: true)))
        await diarizer.close()
    }

    /// Parakeet token timings to words: a token starting with a space (the
    /// SentencePiece word boundary, already normalized by FluidAudio) begins a word.
    static func words(from timings: [TokenTiming]) -> [TimedWord] {
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
                flush()
                text = fragment; start = timing.startTime; end = timing.endTime; open = true
            } else {
                text += fragment
                end = max(end, timing.endTime)
            }
        }
        flush()
        return words
    }
}
