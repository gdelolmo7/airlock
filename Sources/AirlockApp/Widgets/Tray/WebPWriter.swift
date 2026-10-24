import CWebP
import CoreGraphics
import Foundation

/// Writes WebP, which ImageIO cannot: macOS reads it and has no encoder for it.
/// The encoder is Google's own libwebp, built into the app from source (the
/// `CWebP` target), so this needs nothing from the Mac and works on every one.
///
/// It turns pixels into bytes and nothing else. Where the bytes go, and that
/// nothing is ever overwritten, is the caller's job, the same as for every
/// other format the shelf makes.
enum WebPWriter {
    /// Always true: the encoder ships inside the app. It is here so callers ask
    /// the same question of WebP that they ask of ImageIO's formats, rather than
    /// assuming, and so the answer has one place to change if it ever does.
    nonisolated static var isAvailable: Bool { true }

    /// The largest side WebP can describe. A bigger picture is refused here
    /// with a plain nil rather than half-made by the encoder.
    private nonisolated static let largestSide = 16383

    /// A WebP of `image`, or nil if it could not be made. `quality` runs from 0
    /// to 100 and only matters for the lossy kind; 90 is the same "high" the
    /// other lossy formats are asked for. `lossless` keeps every pixel exactly,
    /// at a larger size, which is what a screenshot or a logo wants.
    nonisolated static func data(from image: CGImage, quality: Float = 90,
                                 lossless: Bool = false) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= largestSide, height <= largestSide,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)

        // Drawn into plain 8-bit sRGB, red-green-blue-alpha in that order,
        // whatever the picture was made of: a 16-bit, CMYK or grey source all
        // arrive in the one layout the encoder reads. Core Graphics can only
        // draw see-through pixels premultiplied, so they are undone below.
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: stride, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        unpremultiply(&pixels)

        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            if lossless {
                return WebPEncodeLosslessRGBA(base, Int32(width), Int32(height), Int32(stride), &output)
            }
            return WebPEncodeRGBA(base, Int32(width), Int32(height), Int32(stride),
                                  min(max(quality, 0), 100), &output)
        }
        // The encoder allocates the bytes itself and only its own free may
        // release them; they are copied out first.
        defer { WebPFree(output) }
        guard size > 0, let output else { return nil }
        return Data(bytes: output, count: size)
    }

    /// WebP stores colour and see-through separately ("straight" alpha), and
    /// Core Graphics hands them over multiplied together. Left as they are, a
    /// half-clear edge would come out darker than it went in, every time the
    /// picture was copied. Fully clear pixels have no colour left to recover
    /// and stay black.
    private nonisolated static func unpremultiply(_ pixels: inout [UInt8]) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let alpha = Int(buffer[index + 3])
                if alpha != 0, alpha != 255 {
                    for channel in index..<(index + 3) {
                        let straight = (Int(buffer[channel]) * 255 + alpha / 2) / alpha
                        buffer[channel] = UInt8(min(straight, 255))
                    }
                }
                index += 4
            }
        }
    }
}
