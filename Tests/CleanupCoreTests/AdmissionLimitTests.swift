import XCTest

@testable import CleanupCore

/// The admission limit a host reads from the capability query (#13).
final class AdmissionLimitTests: XCTestCase {

    func testTheCapabilityQueryReportsTheAdmissionLimit() {
        XCTAssertEqual(CleanupRequest.maxTextBytes, 16_384)
        XCTAssertEqual(PackCapabilities.frozenBaseline.maxTextBytes, CleanupRequest.maxTextBytes)
        let custom = PackCapabilities(styles: [], speculativeSwitch: false, auxiliaryGeneration: false,
                                      minResidentMemoryBytes: nil, vocabulary: .request)
        XCTAssertEqual(custom.maxTextBytes, CleanupRequest.maxTextBytes)
    }

    /// The reported value is the one `validate()` enforces, counted in UTF-8 bytes
    /// rather than characters.
    func testTheReportedLimitIsTheEnforcedOne() {
        let limit = PackCapabilities.frozenBaseline.maxTextBytes
        let cases: [(text: String, admitted: Bool)] = [
            (String(repeating: "a", count: limit), true),
            (String(repeating: "a", count: limit + 1), false),
            (String(repeating: "é", count: limit / 2), true),          // 2 bytes each, exactly at the limit
            (String(repeating: "é", count: limit / 2) + "a", false),
            (String(repeating: "👩🏽‍💻", count: limit / 15), true),     // 15 bytes, 1 character each
            (String(repeating: "👩🏽‍💻", count: limit / 15 + 1), false),
        ]
        for (index, c) in cases.enumerated() {
            let admitted = (try? CleanupRequest(c.text).validate()) != nil
            XCTAssertEqual(admitted, c.admitted, "case \(index): \(c.text.utf8.count) bytes")
        }
    }

    /// Exposing the limit does not change the pack schema: it is not encoded.
    func testTheAdmissionLimitIsNotPartOfThePackSchema() throws {
        let data = try JSONEncoder().encode(PackCapabilities.frozenBaseline)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["maxTextBytes"])
    }
}
