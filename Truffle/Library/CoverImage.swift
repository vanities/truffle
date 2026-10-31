import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A playlist cover from a photo: the middle square, at most 1000 px a side, as a JPEG. ImageIO decodes
/// straight to the smaller size, so a 48 MP photo never sits in memory whole.
enum CoverImage {
    static let side = 1000

    static func squareJPEG(from data: Data, side: Int = side, quality: Double = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // EXIF orientations 5 to 8 are turned a quarter, so the stored width is the shown height.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let short = min(width, height)
        let target = min(side, short)
        let longest = Int((Double(max(width, height)) * Double(target) / Double(short)).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let crop = min(scaled.width, scaled.height)
        let square = CGRect(x: (scaled.width - crop) / 2, y: (scaled.height - crop) / 2, width: crop, height: crop)
        guard let cropped = scaled.cropping(to: square) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
