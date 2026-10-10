import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ProbeReport: Codable {
    struct Display: Codable {
        let displayID: UInt32
        let filterWidth: Int
        let filterHeight: Int
        let imageWidth: Int
        let imageHeight: Int
        let captureSeconds: Double
        let jpegEncodeSeconds: Double
        let jpegBytes: Int64
        let heicEncodeSeconds: Double
        let heicBytes: Int64
    }
    let timestamp: String
    let displayCount: Int
    let enumerationSeconds: Double
    let displays: [Display]
}

enum ProbeError: LocalizedError {
    case noDisplays
    case invalidImage
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplays: "没有可采集的显示器。请检查屏幕录制权限。"
        case .invalidImage: "编码后的图片无法解码或尺寸不正确。"
        case .encodingFailed(let format): "\(format) 编码失败。"
        }
    }
}

enum PlatformProbe {
    static func run() async throws -> ProbeReport {
        let start = ProcessInfo.processInfo.systemUptime
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let enumerationSeconds = ProcessInfo.processInfo.systemUptime - start
        guard !content.displays.isEmpty else { throw ProbeError.noDisplays }

        var results: [ProbeReport.Display] = []
        for display in content.displays {
            // 一块屏幕处理完成并释放 CGImage 后，再处理下一块。
            let result = try await captureOne(display, applications: content.applications)
            results.append(result)
        }
        return ProbeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            displayCount: results.count,
            enumerationSeconds: enumerationSeconds,
            displays: results
        )
    }

    private static func captureOne(_ display: SCDisplay, applications: [SCRunningApplication]) async throws -> ProbeReport.Display {
        let selfApplications = applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: selfApplications, exceptingWindows: [])
        let width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        let height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false

        let captureStart = ProcessInfo.processInfo.systemUptime
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let captureSeconds = ProcessInfo.processInfo.systemUptime - captureStart
        let actualWidth = image.width
        let actualHeight = image.height
        let jpeg = try encodeAndVerify(image, type: .jpeg, quality: 0.88)
        let heic = try encodeAndVerify(image, type: .heic, quality: 0.88)

        return ProbeReport.Display(
            displayID: display.displayID,
            filterWidth: width,
            filterHeight: height,
            imageWidth: actualWidth,
            imageHeight: actualHeight,
            captureSeconds: captureSeconds,
            jpegEncodeSeconds: jpeg.seconds,
            jpegBytes: jpeg.bytes,
            heicEncodeSeconds: heic.seconds,
            heicBytes: heic.bytes
        )
    }

    private static func encodeAndVerify(_ image: CGImage, type: UTType, quality: Double) throws -> (seconds: Double, bytes: Int64) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(type.preferredFilenameExtension ?? "img")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = ProcessInfo.processInfo.systemUptime
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ProbeError.encodingFailed(type.identifier)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProbeError.encodingFailed(type.identifier) }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width == image.width, decoded.height == image.height else {
            throw ProbeError.invalidImage
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { throw ProbeError.invalidImage }
        return (seconds, bytes)
    }
}
