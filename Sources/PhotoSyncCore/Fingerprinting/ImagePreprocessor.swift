import CoreGraphics
import CoreML
import ImageIO

public enum ImagePreprocessor {
    public static func prepare(image: CGImage, orientation: CGImagePropertyOrientation,
                               configuration: FingerprintConfiguration) throws -> MLMultiArray {
        let side = configuration.inputSide
        let rotated = [CGImagePropertyOrientation.leftMirrored, .right, .rightMirrored, .left]
            .contains(orientation)
        let width = CGFloat(rotated ? image.height : image.width)
        let height = CGFloat(rotated ? image.width : image.height)
        guard width > 0, height > 0 else { throw AdvancedDedupError.invalidImage }
        let scaleX: CGFloat
        let scaleY: CGFloat
        switch configuration.resizeMode {
        case .stretchFullFrame:
            scaleX = CGFloat(side) / width; scaleY = CGFloat(side) / height
        case .letterbox:
            scaleX = min(CGFloat(side) / width, CGFloat(side) / height); scaleY = scaleX
        }
        let offsetX = (CGFloat(side) - width * scaleX) / 2
        let offsetY = (CGFloat(side) - height * scaleY) / 2
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                              CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .high
            context.translateBy(x: offsetX, y: offsetY)
            context.scaleBy(x: scaleX, y: scaleY)
            let sourceWidth = CGFloat(image.width)
            let sourceHeight = CGFloat(image.height)
            switch orientation {
            case .up: break
            case .upMirrored:
                context.translateBy(x: sourceWidth, y: 0); context.scaleBy(x: -1, y: 1)
            case .down:
                context.translateBy(x: sourceWidth, y: sourceHeight); context.rotate(by: .pi)
            case .downMirrored:
                context.translateBy(x: 0, y: sourceHeight); context.scaleBy(x: 1, y: -1)
            case .leftMirrored:
                context.translateBy(x: sourceHeight, y: sourceWidth)
                context.scaleBy(x: 1, y: -1); context.rotate(by: .pi / 2)
            case .right:
                context.translateBy(x: 0, y: sourceWidth); context.rotate(by: -.pi / 2)
            case .rightMirrored:
                context.scaleBy(x: -1, y: 1); context.rotate(by: .pi / 2)
            case .left:
                context.translateBy(x: sourceHeight, y: 0); context.rotate(by: .pi / 2)
            @unknown default: return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
            return true
        }
        guard rendered else { throw AdvancedDedupError.invalidImage }
        let tensor = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let destination = tensor.dataPointer.bindMemory(to: Float.self, capacity: side * side * 3)
        for channel in 0..<3 {
            for pixel in 0..<(side * side) {
                destination[channel * side * side + pixel] =
                    (Float(rgba[pixel * 4 + channel]) / 255 - configuration.mean[channel]) / configuration.std[channel]
            }
        }
        return tensor
    }
}
