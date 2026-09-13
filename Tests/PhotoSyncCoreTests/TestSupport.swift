import Foundation
import AppKit

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
    try png.write(to: directory.appendingPathComponent("normal.jpg"))
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

enum FixtureError: Error {
    case unavailable(String)
}
