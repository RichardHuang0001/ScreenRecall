import CoreGraphics
import Foundation
// macOS 15 的 ObjC ScreenCaptureKit 类型尚无 Sendable 标注；它们始终留在本 actor 内。
@preconcurrency import ScreenCaptureKit

enum CaptureProviderError: LocalizedError {
    case noDisplays, staleBatch, missingDisplay
    var errorDescription: String? {
        switch self {
        case .noDisplays: "没有可采集的显示器"
        case .staleBatch: "采集批次已失效"
        case .missingDisplay: "显示器已断开"
        }
    }
}

/// 只在 actor 内持有 ScreenCaptureKit 对象；对外传递可发送的元数据。
actor MacScreenCaptureProvider: CaptureProviding {
    enum OutputFormat: Sendable { case jpeg, heic }
    private let root: URL
    private let outputFormat: OutputFormat
    private var activeBatch: UUID?
    private var displays: [UInt32: SCDisplay] = [:]
    private var filters: [UInt32: SCContentFilter] = [:]
    private var excludedApplications: [SCRunningApplication] = []
    private var excludedBundleIDs: Set<String> = []
    private var stagingCleaned = false

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecall-Phase1", isDirectory: true),
         outputFormat: OutputFormat = .jpeg) {
        self.root = root
        self.outputFormat = outputFormat
    }

    func setExcludedBundleIDs(_ identifiers: Set<String>) {
        excludedBundleIDs = identifiers
    }

    func prepareBatch(_ batchID: UUID) async throws -> [DisplayDescriptor] {
        guard activeBatch == nil else { throw CaptureProviderError.staleBatch }
        if !stagingCleaned {
            try cleanupOldStaging()
            stagingCleaned = true
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else { throw CaptureProviderError.noDisplays }
        activeBatch = batchID
        displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let excluded = excludedBundleIDs.union([Bundle.main.bundleIdentifier].compactMap { $0 })
        excludedApplications = content.applications.filter { excluded.contains($0.bundleIdentifier) }
        return content.displays.enumerated().map { order, display in
            let filter = SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: [])
            filters[display.displayID] = filter
            return DisplayResolver.descriptor(for: display, filter: filter, order: order)
        }
    }

    func captureToStaging(display: DisplayDescriptor, batchID: UUID) async throws -> CapturedAsset {
        guard activeBatch == batchID else { throw CaptureProviderError.staleBatch }
        guard displays[display.id] != nil, let filter = filters[display.id] else { throw CaptureProviderError.missingDisplay }
        let config = SCStreamConfiguration()
        config.width = display.pixelWidth
        config.height = display.pixelHeight
        config.showsCursor = false

        let started = Date()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let ended = Date()
        let batchDirectory = root.appendingPathComponent(batchID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = batchDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(outputFormat == .heic ? "heic" : "jpg")
        do {
            let bytes = try outputFormat == .heic ? ImageEncoder.writeHEIC(image, to: url) : ImageEncoder.writeJPEG(image, to: url)
            return CapturedAsset(displayID: display.id, stagingURL: url, width: image.width, height: image.height,
                                 byteCount: bytes, format: outputFormat == .heic ? "heic" : "jpeg", captureStartedAt: started, captureEndedAt: ended)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func finishBatch(_ batchID: UUID) {
        guard activeBatch == batchID else { return }
        displays.removeAll()
        filters.removeAll()
        excludedApplications.removeAll()
        activeBatch = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(batchID.uuidString, isDirectory: true))
    }

    private func cleanupOldStaging() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries where (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture < cutoff {
            try? fileManager.removeItem(at: entry)
        }
    }
}
