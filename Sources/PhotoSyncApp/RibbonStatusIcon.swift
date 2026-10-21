import AppKit
import PhotoSyncCore
import SwiftUI

/// A monochrome vector tracing of the approved folded-S artwork. Transparent seams and
/// state cutouts let AppKit tint the template for light, dark and selected menus.
struct RibbonStatusIcon: View {
    let status: GlobalStatus
    var dimmed = false

    var body: some View {
        Image(nsImage: Self.image(status: status, dimmed: dimmed))
            .accessibilityHidden(true)
    }

    static func image(status: GlobalStatus, dimmed: Bool = false) -> NSImage {
        dimmed ? unmounted : images[status]!
    }

    private static let images = Dictionary(uniqueKeysWithValues:
        GlobalStatus.allCases.map { ($0, makeImage(status: $0)) })
    private static let unmounted = makeImage(status: nil)

    private static func makeImage(status: GlobalStatus?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 20), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            // One uniform scale preserves the reference's 177 × 206 visible silhouette.
            // The unmounted S shares the same scale and top-left alignment.
            let scale = min((rect.width - 1) / 177, (rect.height - 1) / 206)
            context.translateBy(x: rect.midX - 177 * scale / 2, y: rect.midY - 206 * scale / 2)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.black.withAlphaComponent(status == nil ? 0.45 : 1).cgColor)
            fill(status == nil ? fullRibbon : ribbon, in: context)
            if let status {
                fill(tab, in: context)
                context.setBlendMode(.destinationOut)
                fill(marks[status == .preparing ? .running : status]!, in: context)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func fill(_ contours: [[CGFloat]], in context: CGContext) {
        let path = CGMutablePath()
        for coordinates in contours {
            let points = stride(from: 0, to: coordinates.count, by: 2).map {
                CGPoint(x: coordinates[$0], y: coordinates[$0 + 1])
            }
            path.addLines(between: points)
            path.closeSubpath()
        }
        context.addPath(path)
        context.drawPath(using: .eoFill)
    }

    // Contours traced from the approved reference; coordinates retain its aspect ratio.
    private static let ribbon: [[CGFloat]] = [[
            124.0, 2.0, 119.0, 0.0, 111.0, 0.0, 49.0, 14.0, 19.0, 24.0, 11.0, 29.0,
            6.0, 35.0, 3.0, 43.0, 3.0, 82.0, 9.0, 94.0, 16.0, 99.0, 28.0, 104.0,
            71.0, 117.0, 70.0, 119.0, 60.0, 116.0, 50.0, 118.0, 9.0, 130.0, 2.0, 135.0,
            0.0, 139.0, 0.0, 147.0, 13.0, 176.0, 18.0, 181.0, 24.0, 183.0, 32.0, 182.0,
            52.0, 174.0, 68.0, 129.0, 73.0, 120.0, 78.0, 115.0, 86.0, 110.0, 144.0, 89.0,
            140.0, 86.0, 129.0, 83.0, 76.0, 73.0, 30.0, 62.0, 14.0, 55.0, 8.0, 47.0,
            9.0, 46.0, 15.0, 52.0, 23.0, 55.0, 62.0, 65.0, 73.0, 66.0, 85.0, 61.0,
            136.0, 46.0, 143.0, 41.0, 143.0, 35.0, 129.0, 6.0
        ]]
    private static let tab: [[CGFloat]] = [[
            175.0, 98.0, 169.0, 92.0, 157.0, 91.0, 92.0, 114.0, 85.0, 118.0, 79.0, 124.0,
            76.0, 130.0, 57.0, 183.0, 57.0, 199.0, 63.0, 204.0, 71.0, 205.0, 145.0, 189.0,
            158.0, 185.0, 168.0, 180.0, 173.0, 174.0, 176.0, 166.0
        ]]
    private static let marks: [GlobalStatus: [[CGFloat]]] = [
        .completed: [[
            162.0, 126.0, 162.0, 131.0, 115.0, 180.0, 110.0, 179.0, 86.0, 156.0, 86.0, 152.0,
            89.0, 148.0, 97.0, 142.0, 102.0, 144.0, 114.0, 155.0, 149.0, 118.0, 153.0, 118.0
        ]],
        .running: [[
            156.7, 150.9, 155.7, 158.6, 151.8, 166.4, 146.0, 173.1, 138.3, 178.9, 128.6, 182.8,
            115.0, 182.8, 115.0, 187.6, 110.2, 191.5, 94.7, 176.0, 94.7, 172.2, 111.2, 158.6,
            113.1, 158.6, 117.0, 162.5, 116.0, 168.3, 124.7, 169.3, 135.4, 164.4, 141.2, 157.7,
            143.1, 150.9, 146.0, 148.0, 153.8, 148.0
        ], [
            151.8, 128.7, 150.9, 131.6, 135.4, 145.1, 131.5, 145.1, 129.6, 143.2, 129.6, 135.5,
            119.9, 135.5, 113.1, 138.4, 107.3, 143.2, 101.5, 155.7, 92.8, 156.7, 88.9, 151.9,
            94.7, 137.4, 104.4, 127.7, 113.1, 122.9, 129.6, 121.0, 130.5, 116.1, 133.4, 113.2,
            137.3, 113.2
        ]],
        .paused: [[
            104.0, 123.4, 113.6, 123.4, 119.4, 129.3, 118.4, 177.5, 114.6, 181.4, 103.1, 181.4,
            100.2, 179.5, 98.3, 174.5, 99.2, 128.4
        ], [
            140.5, 122.5, 147.2, 123.4, 151.1, 128.4, 151.1, 174.5, 149.2, 178.5, 145.3, 181.4,
            134.7, 181.4, 130.9, 177.5, 130.9, 127.4, 134.7, 123.4
        ]],
        .waiting: [[
            150.1, 116.6, 154.0, 120.5, 154.0, 123.4, 149.2, 128.4, 149.2, 134.2, 146.3, 141.1,
            137.6, 150.0, 137.6, 151.9, 146.3, 160.8, 148.2, 164.7, 148.2, 172.6, 152.0, 175.5,
            152.0, 180.4, 148.2, 184.4, 110.7, 187.3, 100.2, 186.3, 98.3, 184.4, 98.3, 178.5,
            103.1, 174.5, 105.9, 162.8, 115.5, 152.9, 115.5, 151.0, 105.9, 140.1, 105.0, 130.3,
            101.1, 127.4, 100.2, 122.5, 104.0, 118.5
        ], [
            115.5, 139.2, 123.2, 148.0, 124.2, 152.9, 123.2, 155.9, 114.6, 164.7, 112.7, 168.6,
            112.7, 173.6, 115.5, 173.6, 125.1, 163.7, 138.6, 166.7, 138.6, 164.7, 129.9, 155.9,
            129.9, 147.0, 136.7, 139.2
        ]],
        .error: [[
            123.1, 168.0, 129.7, 168.0, 135.4, 173.8, 135.4, 180.7, 130.7, 186.5, 123.1, 187.5,
            116.5, 181.6, 116.5, 174.8
        ], [
            126.0, 115.4, 131.6, 116.3, 136.4, 121.2, 134.5, 158.2, 129.7, 163.1, 124.1, 163.1,
            118.4, 159.2, 116.5, 123.2, 122.2, 116.3
        ]],
    ]
    private static let fullRibbon: [[CGFloat]] = [[
            121.0, 3.0, 114.0, 0.0, 109.0, 0.0, 42.0, 16.0, 12.0, 27.0, 6.0, 32.0,
            1.0, 43.0, 1.0, 80.0, 4.0, 89.0, 11.0, 96.0, 24.0, 102.0, 73.0, 115.0,
            127.0, 127.0, 140.0, 132.0, 145.0, 137.0, 143.0, 138.0, 137.0, 134.0, 124.0, 130.0,
            69.0, 117.0, 10.0, 131.0, 2.0, 137.0, 0.0, 144.0, 11.0, 171.0, 18.0, 182.0,
            22.0, 184.0, 35.0, 184.0, 97.0, 171.0, 135.0, 160.0, 146.0, 154.0, 149.0, 150.0,
            152.0, 142.0, 151.0, 104.0, 148.0, 98.0, 142.0, 92.0, 117.0, 83.0, 29.0, 62.0,
            12.0, 55.0, 7.0, 50.0, 8.0, 48.0, 11.0, 51.0, 23.0, 56.0, 67.0, 67.0,
            135.0, 46.0, 139.0, 42.0, 139.0, 37.0, 124.0, 6.0
        ]]
}
