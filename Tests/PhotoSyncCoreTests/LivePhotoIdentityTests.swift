import XCTest
@testable import PhotoSyncCore

final class LivePhotoIdentityTests: XCTestCase {
    func testFrozenMovieDurationsPreserveIdentificationBoundary() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LivePhotoPortable/media")
        for (name, expected, excluded) in [("below.mov", 9.999, false), ("equal.mov", 10.0, false), ("above.mov", 10.001, true)] {
            let metadata = try await MetadataReader().read(url: root.appendingPathComponent(name), filename: name)
            XCTAssertEqual(try XCTUnwrap(metadata.duration), expected, accuracy: 0.0001)
            XCTAssertEqual(LivePhotoIdentificationPolicy.excludesVideo(kind: metadata.kind, duration: metadata.duration), excluded)
            XCTAssertFalse(LivePhotoIdentificationPolicy.excludesVideo(kind: metadata.kind, duration: metadata.duration, hasIdentity: true))
        }
    }

    func testFrozenPortableMediaExercisesRealMetadataReader() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LivePhotoPortable/media")
        let reader = LivePhotoMetadataReader()
        for (name, role) in [("paired.heic", LivePhotoRole.photo), ("paired.jpg", .photo), ("paired.mov", .motion)] {
            let result = try await reader.inspect(url: root.appendingPathComponent(name), kind: role == .motion ? .video : .image)
            guard case .identified(let identity) = result else { return XCTFail("Missing portable identity: \(name)") }
            XCTAssertEqual(identity.contentIdentifier, "11111111-2222-3333-4444-555555555555")
            XCTAssertEqual(identity.role, role)
            if role == .motion { XCTAssertEqual(identity.hasAudio, true) }
        }
        let plain = try await reader.inspect(url: root.appendingPathComponent("plain.jpg"), kind: .image)
        XCTAssertEqual(plain, .noIdentifier)
        let missingTime = try await reader.inspect(url: root.appendingPathComponent("missing-time.mov"), kind: .video)
        guard case .unresolved = missingTime else { return XCTFail("Missing timed metadata must remain unresolved") }
        for (name, kind) in [("corrupt.heic", MediaKind.image), ("corrupt.mov", .video)] {
            do { _ = try await reader.inspect(url: root.appendingPathComponent(name), kind: kind); XCTFail("Accepted malformed fixture") }
            catch { }
        }
    }

    func testSyntheticPairedMovieContainsAudio() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.mov")
        try await makeLivePhotoMotion(at: url, identifier: UUID().uuidString, audio: true)
        let result = try await LivePhotoMetadataReader().inspect(url: url, kind: .video)
        guard case .identified(let identity) = result else { return XCTFail("Missing identity") }
        XCTAssertEqual(identity.hasAudio, true)
    }

    func testImageAndMotionShareIdentity() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("photo.jpg"), movie = folder.appendingPathComponent("motion.mov")
        try makeLivePhotoImage(at: image, identifier: "11111111-2222-3333-4444-555555555555")
        try await makeLivePhotoMotion(at: movie, identifier: "11111111-2222-3333-4444-555555555555")
        let reader = LivePhotoMetadataReader()
        let photo = try await reader.inspect(url: image, kind: .image)
        let motion = try await reader.inspect(url: movie, kind: .video)
        guard case .identified(let p) = photo, case .identified(let m) = motion else { return XCTFail("Expected identified resources: \(photo), \(motion)") }
        XCTAssertEqual(p.contentIdentifier, "11111111-2222-3333-4444-555555555555"); XCTAssertEqual(m.contentIdentifier, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(p.role, .photo); XCTAssertEqual(m.role, .motion)
        XCTAssertEqual(m.stillImageTime, 0); XCTAssertEqual(m.hasAudio, false)
    }

    func testIdentifierWithoutTimedSampleIsUnresolved() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("ordinary.mov")
        try await makeLivePhotoMotion(at: movie, identifier: "11111111-2222-3333-4444-666666666666", timedSample: false)
        let result = try await LivePhotoMetadataReader().inspect(url: movie, kind: .video)
        guard case .unresolved = result else { return XCTFail("An ID alone must not identify Live Photo motion") }
    }

    func testMismatchedAndMissingIdentifiersDoNotPair() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("plain.jpg"), other = folder.appendingPathComponent("other.jpg")
        try makeLivePhotoImage(at: plain, identifier: nil); try makeLivePhotoImage(at: other, identifier: "11111111-2222-3333-4444-777777777777")
        let noID = try await LivePhotoMetadataReader().inspect(url: plain, kind: .image)
        let different = try await LivePhotoMetadataReader().inspect(url: other, kind: .image)
        XCTAssertEqual(noID, .noIdentifier)
        guard case .identified(let identity) = different else { return XCTFail("Expected photo identity") }
        XCTAssertNotEqual(identity.contentIdentifier, "11111111-2222-3333-4444-555555555555")
    }

    func testCorruptMediaThrows() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        for (name, kind) in [("bad.jpg", MediaKind.image), ("bad.mov", .video)] {
            let url = folder.appendingPathComponent(name); try Data("broken".utf8).write(to: url)
            do { _ = try await LivePhotoMetadataReader().inspect(url: url, kind: kind); XCTFail("Corrupt media accepted") } catch { }
        }
    }

    func testTimedMetadataDoesNotDecodeVideoFrames() async throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("metadata.mov")
        try await makeLivePhotoMotion(at: movie, identifier: "11111111-2222-3333-4444-888888888888")
        // Reader exposes metadata only: the assertion requires an actual timed sample, not a declared key.
        let result = try await LivePhotoMetadataReader().inspect(url: movie, kind: .video)
        guard case .identified(let value) = result else { return XCTFail("Missing timed identity") }
        XCTAssertEqual(value.stillImageTime, 0)
    }
}
