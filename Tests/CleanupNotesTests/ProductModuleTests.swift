import PomvoxDiarization
import PomvoxNotes
import XCTest

/// The README and speaker-notes guide tell hosts to `import PomvoxNotes` and
/// `import PomvoxDiarization`. Those are product names; this fails to compile if
/// either stops being an importable module that re-exports its types.
final class ProductModuleTests: XCTestCase {
    func testDocumentedProductModulesReexportTheirTypes() {
        let source = TranscriptResult(turns: [], elapsedMS: 0)
        XCTAssertTrue(Notes.extract(from: source).items.isEmpty)
        XCTAssertEqual(DiarizerPackLoader.pipeline, "pyannote-community-1-offline")
    }
}
