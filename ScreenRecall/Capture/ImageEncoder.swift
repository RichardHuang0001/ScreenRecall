import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageEncodingError: LocalizedError {
    case failed, invalidOutput
    var errorDescription: String? {
        switch self {
        case .failed: "图片编码失败"
        case .invalidOutput: "编码文件校验失败"
        }
    }
}

enum ImageEncoder {
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.88) throws -> Int64 {
        try write(image, to: url, type: .jpeg, quality: quality)
    }

    static func writeHEIC(_ image: CGImage, to url: URL, quality: Double = 0.88) throws -> Int64 {
        try write(image, to: url, type: .heic, quality: quality)
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double) throws -> Int64 {
        try autoreleasepool {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ImageEncodingError.failed
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageEncodingError.failed }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width == image.width, height == image.height else {
                throw ImageEncodingError.invalidOutput
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else { throw ImageEncodingError.invalidOutput }
            return bytes
        }
    }
}
