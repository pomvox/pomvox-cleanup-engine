import Foundation
import PomvoxCleanup
import PomvoxCleanupMLX
import PomvoxDiarizationFluid
import PomvoxNotes
import SwiftUI

/// Packaging check for iOS: links every engine library an iPhone app would use.
/// It downloads nothing. Copy installed packs into the app's Documents directory
/// (`simplewords-v3`, `pyannote-community1-coreml`) to run the smoke check on a
/// device; without them it reports which pack is missing. Not a benchmark.
@main
struct iOSConsumerApp: App {
    var body: some Scene {
        WindowGroup { SmokeView() }
    }
}

struct SmokeView: View {
    @State private var log = "Linked: \(FluidDiarizer.runtimeName), \(RuntimeFactory.mlx.name)"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Run smoke check") { Task { log = await Smoke.run() } }
            ScrollView { Text(log).font(.footnote.monospaced()).textSelection(.enabled) }
        }
        .padding()
    }
}

enum Smoke {
    static func run() async -> String {
        let documents = URL.documentsDirectory
        var lines: [String] = []
        do {
            let cleaner = try await Cleaner.open(pack: .directory(documents.appending(path: "simplewords-v3")),
                                                 runtime: .mlx, policy: .local)
            let transcript = Transcript(turns: [SpeakerTurn(speaker: SpeakerLabel("S1"),
                text: "um so we decided to ship on friday. i will send the report by thursday")])
            let cleaned = try await cleaner.clean(transcript)
            try await cleaner.closeAndWait()
            lines.append("cleanup: \(cleaned.turns.map(\.result.status))")
            lines.append(NotesRenderer.markdown(Notes.extract(from: cleaned)))
        } catch {
            lines.append("cleanup: \(error)")
        }
        do {
            let pack = try DiarizerPackLoader.validate(directory: documents.appending(path: "pyannote-community1-coreml"))
            let diarizer = try await FluidDiarizer.open(pack: pack)
            lines.append("diarizer: opened in \(Int(diarizer.preparationMS)) ms")
            await diarizer.close()
        } catch {
            lines.append("diarizer: \(error)")
        }
        return lines.joined(separator: "\n")
    }
}
