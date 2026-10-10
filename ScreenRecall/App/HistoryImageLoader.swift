import CoreGraphics
import Foundation
import ImageIO

struct DecodedHistoryImage: @unchecked Sendable {
    let image: CGImage
    var memoryCost: Int { image.bytesPerRow * image.height }
}

enum HistoryImageError: LocalizedError {
    case cannotDecode
    var errorDescription: String? { "历史图片无法读取" }
}

/// 文件使用保护覆盖后台解码全过程；最多两个图像解码任务同时运行。
actor HistoryImageLoader {
    private let sink: PersistentCaptureSink
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(sink: PersistentCaptureSink) { self.sink = sink }

    func load(assetID: String, maximumPixelSize: Int) async throws -> DecodedHistoryImage {
        await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()
        let url = try await sink.acquireAssetURL(assetID)
        do {
            let size = max(64, min(maximumPixelSize, 4096))
            let result = try await Task.detached(priority: .utility) {
                try Self.decode(url: url, maximumPixelSize: size)
            }.value
            await sink.releaseAsset(assetID)
            try Task.checkCancellation()
            return result
        } catch {
            await sink.releaseAsset(assetID)
            throw error
        }
    }

    private func acquireSlot() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { continuation in waiting.append(continuation) }
    }

    private func releaseSlot() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }

    nonisolated private static func decode(url: URL, maximumPixelSize: Int) throws -> DecodedHistoryImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw HistoryImageError.cannotDecode }
        return DecodedHistoryImage(image: image)
    }
}

private final class CachedHistoryImage: NSObject {
    let decoded: DecodedHistoryImage
    init(_ decoded: DecodedHistoryImage) { self.decoded = decoded }
}

@MainActor
final class HistoryThumbnailCache {
    private let cache = NSCache<NSString, CachedHistoryImage>()

    init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func image(for assetID: String) -> DecodedHistoryImage? {
        cache.object(forKey: assetID as NSString)?.decoded
    }

    func insert(_ image: DecodedHistoryImage, for assetID: String) {
        cache.setObject(CachedHistoryImage(image), forKey: assetID as NSString, cost: image.memoryCost)
    }

    func clear() { cache.removeAllObjects() }
}
