import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoSyncTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func sourceFixtureDirectory() throws -> URL {
    let directory = try temporaryDirectory()
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    image.setColor(NSColor.red, atX: 0, y: 0)
    guard let png = image.representation(using: .png, properties: [:]) else {
        throw FixtureError.unavailable("unable to create PNG")
    }

    try png.write(to: directory.appendingPathComponent("no-exif.png"))
    try makeJPEGFixture(
        at: directory.appendingPathComponent("normal.jpg"),
        captureTime: "2026:09:13 10:15:30",
        offset: "+08:00",
        make: "Fixture Make",
        model: "Fixture Model"
    )
    try png.write(to: directory.appendingPathComponent("photo.CR3"))
    try Data("not an image".utf8).write(to: directory.appendingPathComponent("corrupt.jpg"))
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("subdirectory"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(".hidden"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("bundle.photoslibrary"), withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("linked.png"),
        withDestinationURL: directory.appendingPathComponent("no-exif.png")
    )
    return directory
}

private func makeJPEGFixture(
    at url: URL,
    captureTime: String,
    offset: String,
    make: String,
    model: String
) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw FixtureError.unavailable("unable to create JPEG destination")
    }
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    guard let cgImage = image.cgImage else { throw FixtureError.unavailable("unable to create JPEG image") }
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: captureTime,
            kCGImagePropertyExifOffsetTimeOriginal: offset
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: make,
            kCGImagePropertyTIFFModel: model
        ]
    ]
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.unavailable("unable to finalize JPEG") }
}

enum FixtureError: Error {
    case unavailable(String)
}
