import XCTest
import PhotoSyncCore

func media(
    _ name: String = "IMG_0001.JPG",
    second: Int64? = nil,
    make: String? = nil,
    model: String? = nil
) -> MediaMetadata {
    MediaMetadata(
        filename: name,
        kind: .image,
        captureSecond: second,
        rawCaptureTime: nil,
        make: make,
        model: model,
        width: 100,
        height: 100,
        duration: nil
    )
}

final class DuplicatePolicyTests: XCTestCase {
    func testDifferentFilenameAlwaysImports() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media("B.JPG"))

        XCTAssertEqual(DuplicatePolicy().evaluate(media("A.JPG"), candidates: [candidate]), .importNew)
    }

    func testOneSecondDifferenceExcludesCandidate() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media(second: 101))

        XCTAssertEqual(DuplicatePolicy().evaluate(media(second: 100), candidates: [candidate]), .importNew)
    }

    func testMissingTimeIsConservative() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media())

        XCTAssertEqual(
            DuplicatePolicy().evaluate(media(second: 100), candidates: [candidate]),
            .skip(candidateKeys: ["photos:1"])
        )
    }

    func testDifferentNormalizedDeviceExcludesCandidate() {
        let candidate = MatchCandidate(
            key: "photos:1",
            metadata: media(make: "Canon", model: " EOS R5 ")
        )

        XCTAssertEqual(
            DuplicatePolicy().evaluate(media(make: "canon", model: "EOS   R6"), candidates: [candidate]),
            .importNew
        )
    }

    func testNormalizedMatchingDeviceRetainsCandidate() {
        let candidate = MatchCandidate(
            key: "photos:1",
            metadata: media(make: "  CANON", model: "EOS   R5")
        )

        XCTAssertEqual(
            DuplicatePolicy().evaluate(media(make: "canon", model: "eos r5  "), candidates: [candidate]),
            .skip(candidateKeys: ["photos:1"])
        )
    }

    func testMissingDevicePartDoesNotExcludeCandidate() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media(make: "Canon"))

        XCTAssertEqual(
            DuplicatePolicy().evaluate(media(make: "Nikon", model: "Z8"), candidates: [candidate]),
            .skip(candidateKeys: ["photos:1"])
        )
    }

    func testSameSecondRetainsCandidateRegardlessOfSubsecondSourcePrecision() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media(second: 100))

        XCTAssertEqual(DuplicatePolicy().evaluate(media(second: 100), candidates: [candidate]), .skip(candidateKeys: ["photos:1"]))
    }

    func testUnknownTimezoneRawCaptureTimeDoesNotExcludeCandidate() {
        let source = MediaMetadata(
            filename: "IMG_0001.JPG", kind: .image, captureSecond: nil,
            rawCaptureTime: "2026-09-13 10:15:30", make: nil, model: nil,
            width: 100, height: 100, duration: nil
        )
        let candidate = MatchCandidate(key: "photos:1", metadata: media(second: 100))

        XCTAssertEqual(DuplicatePolicy().evaluate(source, candidates: [candidate]), .skip(candidateKeys: ["photos:1"]))
    }

    func testFilenameCaseDifferenceImports() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media("img_0001.jpg"))

        XCTAssertEqual(DuplicatePolicy().evaluate(media("IMG_0001.JPG"), candidates: [candidate]), .importNew)
    }

    func testOneUnresolvedCandidateCausesSortedSkip() {
        let candidates = [
            MatchCandidate(key: "photos:z", metadata: media(second: 101)),
            MatchCandidate(key: "photos:b", metadata: media(second: 100)),
            MatchCandidate(key: "photos:a", metadata: media(second: 100, make: "Canon", model: "R5")),
        ]

        XCTAssertEqual(
            DuplicatePolicy().evaluate(media(second: 100), candidates: candidates),
            .skip(candidateKeys: ["photos:a", "photos:b"])
        )
    }
}
