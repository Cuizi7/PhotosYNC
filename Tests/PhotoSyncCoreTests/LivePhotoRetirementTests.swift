import XCTest
@testable import PhotoSyncCore

final class LivePhotoRetirementTests: XCTestCase {
    func testRequiresBytesAndRemainingProtectedFields() {
        let known = knownLivePhotoSnapshot()
        XCTAssertEqual(LivePhotoRetirementPolicy.evaluate(old: known, target: known, resourcePreserved: true), .eligible)
        XCTAssertNotEqual(LivePhotoRetirementPolicy.evaluate(old: known, target: known, resourcePreserved: false), .eligible)
        for key in ["caption", "keywords", "date", "location", "rating", "albums"] {
            var old = known
            switch key { case "caption": old.caption = .unknown
            case "keywords": old.keywords = .unknown; case "date": old.creationDate = .unknown
            case "location": old.location = .unknown; case "rating": old.rating = .unknown; default: old.albumIDs = .unknown }
            XCTAssertNotEqual(LivePhotoRetirementPolicy.evaluate(old: old, target: known, resourcePreserved: true), .eligible, key)
        }
    }
    func testTitlesDoNotPreventRetirementOfPreservedResources() {
        let titles: [PreservedField<String>] = [.unknown, .emptyOrNotApplicable, .value("old title"), .value("different title")]
        for oldTitle in titles {
            for targetTitle in titles {
                var old = knownLivePhotoSnapshot(), target = knownLivePhotoSnapshot()
                old.title = oldTitle; target.title = targetTitle
                XCTAssertEqual(LivePhotoRetirementPolicy.evaluate(old: old, target: target, resourcePreserved: true), .eligible)
            }
        }
    }
    func testEditsExtraResourcesAndSharedAreRetained() {
        for key in ["edit", "extra", "shared"] {
            var old = knownLivePhotoSnapshot()
            if key == "edit" { old.hasAdjustments = .value(true) }
            if key == "extra" { old.hasExtraResources = .value(true) }
            if key == "shared" { old.isSharedAlbum = .value(true) }
            XCTAssertNotEqual(LivePhotoRetirementPolicy.evaluate(old: old, target: knownLivePhotoSnapshot(), resourcePreserved: true), .eligible)
        }
    }
    func testMergeAlbumsFlagsAndPreserveConflict() {
        var photo = knownLivePhotoSnapshot(), motion = knownLivePhotoSnapshot()
        photo.albumIDs = .value(["a"]); motion.albumIDs = .value(["b"])
        photo.favorite = .value(true); motion.hidden = .value(true)
        photo.creationDate = .value(Date(timeIntervalSince1970: 10)); motion.creationDate = .value(Date(timeIntervalSince1970: 20))
        let target = LivePhotoRetirementPolicy.mergeForCreation(photo: photo, motion: motion)
        XCTAssertEqual(target.albumIDs, .value(["a", "b"])); XCTAssertEqual(target.favorite, .value(true)); XCTAssertEqual(target.hidden, .value(true))
        XCTAssertEqual(target.creationDate, photo.creationDate)
        XCTAssertNotEqual(LivePhotoRetirementPolicy.evaluate(old: motion, target: target, resourcePreserved: true), .eligible)
    }
    func testExistingTargetIsNotRewrittenToMatchOldInformation() {
        var old = knownLivePhotoSnapshot(); old.caption = .value("keep me")
        XCTAssertNotEqual(LivePhotoRetirementPolicy.evaluate(old: old, target: knownLivePhotoSnapshot(), resourcePreserved: true), .eligible)
    }
}
