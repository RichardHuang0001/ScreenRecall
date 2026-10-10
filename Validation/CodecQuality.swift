import Foundation
import ImageIO
import UniformTypeIdentifiers

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("input image") }
for (name, type) in [("jpeg", UTType.jpeg), ("heic", UTType.heic)] {
    let target = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("test.\(name)")
    guard let destination = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else {
        fatalError("destination \(name)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("encode \(name)") }
}
