import CoreGraphics
import Foundation

struct HistorySmokeReport: Encodable {
    let firstPage: Int
    let secondPageTotal: Int
    let finalTotal: Int
    let allRowsHaveTwoScreens: Bool
    let thumbnailWidth: Int
    let thumbnailHeight: Int
    let cacheReleasedOnClose: Bool
    let dateJumpBeforeTarget: Bool
    let originalDataMatches: Bool
    let exportAndReplaceMatch: Bool
}

enum HistorySmoke {
    private enum SmokeError: Error { case validationFailed }
    static func makeDataset() async throws -> (StoragePaths, PersistentCaptureSink) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecall-Phase4Smoke-\(UUID().uuidString)", isDirectory: true)
        do {
        let paths = try StoragePaths(root: root)
        let sink = try PersistentCaptureSink(paths: paths)
        for index in 0..<120 {
            let id = UUID()
            let date = Date().addingTimeInterval(Double(index - 119) * 30)
            let displays = [DisplayDescriptor(id: 1, order: 0, pixelWidth: index == 119 ? 1200 : 64,
                                              pixelHeight: index == 119 ? 800 : 40, pointPixelScale: 1),
                            DisplayDescriptor(id: 2, order: 1, pixelWidth: 64, pixelHeight: 40, pointPixelScale: 1)]
            try await sink.beginBatch(id, startedAt: date, displays: displays, generation: 0)
            for display in displays {
                let asset = try makeAsset(paths: paths, batchID: id, display: display)
                try await sink.consume(asset, batchID: id, generation: 0)
            }
            let summary = CaptureBatchSummary(id: id, startedAt: date, endedAt: date,
                                              status: .complete, expectedCount: 2,
                                              outcomes: displays.map { FrameOutcome(displayID: $0.id, succeeded: true, error: nil) },
                                              errorSummary: nil)
            try await sink.finish(summary, generation: 0)
        }
        return (paths, sink)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @MainActor
    static func verify(paths: StoragePaths, sink: PersistentCaptureSink) async throws -> HistorySmokeReport {
        let model = HistoryViewModel(sink: sink)
        await model.reload()
        let first = model.batches.count
        await model.loadMore()
        let second = model.batches.count
        await model.loadMore()
        let final = model.batches.count
        var allTwo = true
        for batch in model.batches {
            if try await sink.frames(batchID: batch.id).count != 2 { allTwo = false }
        }
        let frames = try await sink.frames(batchID: model.batches[0].id)
        guard let assetID = frames[0].assetID else { throw HistoryImageError.cannotDecode }
        let thumb = try await model.loader.load(assetID: assetID, maximumPixelSize: 480)
        model.cache.insert(thumb, for: assetID)
        let assetURL = try await sink.acquireAssetURL(assetID)
        let expectedData = try Data(contentsOf: assetURL)
        await sink.releaseAsset(assetID)
        let (copyData, _) = try await HistoryAssetActions.originalData(assetID: assetID, sink: sink)
        let exported = paths.root.appendingPathComponent("history-export-test.jpg")
        try await HistoryAssetActions.export(assetID: assetID, sink: sink, to: exported)
        let firstExportMatches = try Data(contentsOf: exported) == expectedData
        try Data("older file".utf8).write(to: exported, options: .atomic)
        try await HistoryAssetActions.export(assetID: assetID, sink: sink, to: exported)
        let replacementMatches = try Data(contentsOf: exported) == expectedData
        let target = model.batches[60].startedAt
        await model.reload(before: target)
        let jumpValid = model.batches.first.map { $0.startedAt < target } ?? false
        model.clearForClose()
        let report = HistorySmokeReport(firstPage: first, secondPageTotal: second, finalTotal: final,
                                  allRowsHaveTwoScreens: allTwo,
                                  thumbnailWidth: thumb.image.width, thumbnailHeight: thumb.image.height,
                                  cacheReleasedOnClose: model.cache.image(for: assetID) == nil,
                                  dateJumpBeforeTarget: jumpValid,
                                  originalDataMatches: copyData == expectedData,
                                  exportAndReplaceMatch: firstExportMatches && replacementMatches)
        guard report.firstPage == 50, report.secondPageTotal == 100, report.finalTotal == 120,
              report.allRowsHaveTwoScreens, report.thumbnailWidth <= 480, report.thumbnailHeight <= 480,
              report.cacheReleasedOnClose, report.dateJumpBeforeTarget,
              report.originalDataMatches, report.exportAndReplaceMatch else { throw SmokeError.validationFailed }
        return report
    }

    private static func makeAsset(paths: StoragePaths, batchID: UUID, display: DisplayDescriptor) throws -> CapturedAsset {
        let directory = paths.staging.appendingPathComponent(batchID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        guard let context = CGContext(data: nil, width: display.pixelWidth, height: display.pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw HistoryImageError.cannotDecode
        }
        context.setFillColor(display.id == 1 ? CGColor(red: 0.15, green: 0.3, blue: 0.8, alpha: 1) :
                                                  CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: display.pixelWidth, height: display.pixelHeight))
        guard let image = context.makeImage() else { throw HistoryImageError.cannotDecode }
        let bytes = try ImageEncoder.writeJPEG(image, to: url)
        return CapturedAsset(displayID: display.id, stagingURL: url, width: display.pixelWidth,
                             height: display.pixelHeight, byteCount: bytes, format: "jpeg",
                             captureStartedAt: Date(), captureEndedAt: Date())
    }
}
