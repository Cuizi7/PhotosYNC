import AppKit
import XCTest
@testable import PhotoSyncCore

@MainActor
final class StatusIconTests: XCTestCase {
    func testNativeArtworkMatchesApprovedDesignAtEqualHeight() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf:
            root.appendingPathComponent("Design/Icons/MenuBar/Selected-Design.png"))))
        let columns: [(GlobalStatus, Int, Int, Bool)] = [(.completed, 45, 240, false),
            (.running, 273, 470, false), (.paused, 500, 700, false), (.waiting, 730, 925, false),
            (.error, 960, 1160, false), (.preparing, 273, 470, false), (.waiting, 1428, 1600, true)]
        for (status, left, right, dimmed) in columns {
            let expected = silhouette(reference, bounds: NSRect(x: left, y: 278, width: right - left, height: 218)) {
                max($0.redComponent, $0.greenComponent, $0.blueComponent) < (dimmed ? 0.82 : 0.5)
            }
            let actualBitmap = try raster(RibbonStatusIcon.image(status: status, dimmed: dimmed), scale: 16)
            let actual = silhouette(actualBitmap,
                bounds: NSRect(x: 0, y: 0, width: actualBitmap.pixelsWide, height: actualBitmap.pixelsHigh)) {
                $0.alphaComponent > (dimmed ? 0.225 : 0.5)
            }
            let intersection = expected.intersection(actual).count
            let union = expected.union(actual).count
            let overlap = Double(intersection) / Double(max(1, union))
            print("Approved icon silhouette \(status) dimmed=\(dimmed): IoU=\(overlap)")
            XCTAssertGreaterThan(overlap, 0.88,
                "\(status): compare visible silhouettes at equal height without stretching their widths")
        }
    }

    func testTemplateStatesStayDistinctAtMenuBarResolutions() throws {
        for scale in [1, 2] {
            var states = Set<Data>()
            var brandStrips = Set<Data>()
            for status in GlobalStatus.allCases {
                let image = RibbonStatusIcon.image(status: status)
                XCTAssertTrue(image.isTemplate)
                XCTAssertEqual(image.size, NSSize(width: 18, height: 20))
                let bitmap = try raster(image, scale: scale)
                var bytes = Data()
                var brand = Data()
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let alpha = try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
                        bytes.append(UInt8((alpha * 255).rounded()))
                        if x < 7 * scale { brand.append(UInt8((alpha * 255).rounded())) }
                    }
                }
                states.insert(bytes)
                brandStrips.insert(brand)
            }
            XCTAssertEqual(states.count, GlobalStatus.allCases.count - 1, "Preparing reuses the running mark")
            XCTAssertEqual(brandStrips.count, 1, "State marks must retain the same left-hand S silhouette")
        }
    }

    func testUnmountedIconUsesTranslucentTemplateWithoutAStatusTab() throws {
        for scale in [1, 2] {
            let bitmap = try raster(RibbonStatusIcon.image(status: .waiting, dimmed: true), scale: scale)
            var peak: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    peak = max(peak, try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent)
                }
            }
            XCTAssertGreaterThan(peak, 0.35)
            XCTAssertLessThan(peak, 0.55, "The system must be able to tint the gray state on either appearance")
        }
    }

    private func raster(_ image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width) * scale, pixelsHigh: Int(image.size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return bitmap
    }

    /// Normalize by visible height only. A distorted width must remain visible to this test.
    private func silhouette(_ bitmap: NSBitmapImageRep, bounds: NSRect,
        contains: (NSColor) -> Bool) -> Set<Int> {
        var points: [(Int, Int)] = []
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                if let color = bitmap.colorAt(x: x, y: y), contains(color) { points.append((x, y)) }
            }
        }
        guard let left = points.map(\.0).min(), let right = points.map(\.0).max(),
              let top = points.map(\.1).min(), let bottom = points.map(\.1).max() else { return [] }
        let factor = 180.0 / Double(bottom - top + 1)
        let offset = (256.0 - Double(right - left + 1) * factor) / 2
        let occupied = Set(points.map { ($0.1 - top) * (right - left + 1) + $0.0 - left })
        var result = Set<Int>()
        for y in 0..<180 {
            for x in 0..<256 {
                let sourceX = Int(floor((Double(x) + 0.5 - offset) / factor))
                let sourceY = min(bottom - top, Int(floor((Double(y) + 0.5) / factor)))
                if sourceX >= 0, sourceX <= right - left,
                   occupied.contains(sourceY * (right - left + 1) + sourceX) {
                    result.insert(y * 256 + x)
                }
            }
        }
        return result
    }
}
