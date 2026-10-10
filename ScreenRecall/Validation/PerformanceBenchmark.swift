import Foundation

/// 仅由显式命令行参数启动；图片只存于独立临时目录，报告不包含图片内容。
enum PerformanceBenchmark {
    struct Frame: Encodable {
        let displayID: UInt32
        let width: Int
        let height: Int
        let captureAndEncodeSeconds: Double
        let screenshotSeconds: Double
        let storeSeconds: Double
        let bytes: Int64
        let error: String?
    }

    struct Batch: Encodable {
        let startedAt: Date
        let status: String
        let prepareSeconds: Double
        let beginSeconds: Double
        let finishSeconds: Double
        let totalSeconds: Double
        let frames: [Frame]
    }

    struct Report: Encodable {
        let format: String
        let screenLimit: Int
        let intervalSeconds: Int
        let batches: [Batch]
        let totalStoredBytes: Int64
        let error: String?
    }

    static func run(arguments: [String]) async throws -> Report {
        func value(_ key: String, fallback: String) -> String {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return fallback }
            return arguments[index + 1]
        }
        let formatName = value("--format", fallback: "jpeg")
        let format: MacScreenCaptureProvider.OutputFormat = formatName == "heic" ? .heic : .jpeg
        let screenLimit = max(1, min(8, Int(value("--screens", fallback: "2")) ?? 2))
        let batchCount = max(1, min(10, Int(value("--batches", fallback: "3")) ?? 3))
        let interval = max(1, min(120, Int(value("--interval", fallback: "30")) ?? 30))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecall-Phase5-\(UUID().uuidString)", isDirectory: true)
        let paths = try StoragePaths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = try PersistentCaptureSink(paths: paths)
        let provider = MacScreenCaptureProvider(root: paths.staging, outputFormat: format)
        try await sink.recover()
        var batches: [Batch] = []
        let runStart = ProcessInfo.processInfo.systemUptime
        for index in 0..<batchCount {
            let scheduled = runStart + Double(index * interval)
            let delay = scheduled - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let batchID = UUID()
            let wallStart = Date()
            let batchStart = ProcessInfo.processInfo.systemUptime
            var prepareSeconds = 0.0
            var beginSeconds = 0.0
            var finishSeconds = 0.0
            var frames: [Frame] = []
            var outcomes: [FrameOutcome] = []
            var selected: [DisplayDescriptor] = []
            var batchError: String?
            do {
                let prepareStart = ProcessInfo.processInfo.systemUptime
                selected = Array(try await provider.prepareBatch(batchID).prefix(screenLimit))
                prepareSeconds = ProcessInfo.processInfo.systemUptime - prepareStart
                let beginStart = ProcessInfo.processInfo.systemUptime
                try await sink.beginBatch(batchID, startedAt: wallStart, displays: selected, generation: 0)
                beginSeconds = ProcessInfo.processInfo.systemUptime - beginStart
                for display in selected {
                    do {
                        let captureStart = ProcessInfo.processInfo.systemUptime
                        let asset = try await provider.captureToStaging(display: display, batchID: batchID)
                        let captureSeconds = ProcessInfo.processInfo.systemUptime - captureStart
                        let storeStart = ProcessInfo.processInfo.systemUptime
                        try await sink.consume(asset, batchID: batchID, generation: 0)
                        let storeSeconds = ProcessInfo.processInfo.systemUptime - storeStart
                        frames.append(Frame(displayID: display.id, width: asset.width, height: asset.height,
                                            captureAndEncodeSeconds: captureSeconds,
                                            screenshotSeconds: asset.captureEndedAt.timeIntervalSince(asset.captureStartedAt),
                                            storeSeconds: storeSeconds,
                                            bytes: asset.byteCount, error: nil))
                        outcomes.append(FrameOutcome(displayID: display.id, succeeded: true, error: nil))
                    } catch {
                        let message = error.localizedDescription
                        frames.append(Frame(displayID: display.id, width: display.pixelWidth, height: display.pixelHeight,
                                            captureAndEncodeSeconds: 0, screenshotSeconds: 0,
                                            storeSeconds: 0, bytes: 0, error: message))
                        outcomes.append(FrameOutcome(displayID: display.id, succeeded: false, error: message))
                        try? await sink.recordFailure(display: display, batchID: batchID, generation: 0, message: message)
                    }
                }
            } catch { batchError = error.localizedDescription }
            await provider.finishBatch(batchID)
            let status: CaptureBatchStatus = batchError == nil && !selected.isEmpty && outcomes.allSatisfy(\.succeeded)
                ? .complete : outcomes.contains(where: \.succeeded) ? .partial : .failed
            let summary = CaptureBatchSummary(id: batchID, startedAt: wallStart, endedAt: Date(), status: status,
                                              expectedCount: selected.count, outcomes: outcomes, errorSummary: batchError)
            let finishStart = ProcessInfo.processInfo.systemUptime
            if batchError == nil { try await sink.finish(summary, generation: 0) }
            finishSeconds = ProcessInfo.processInfo.systemUptime - finishStart
            batches.append(Batch(startedAt: wallStart, status: status.rawValue, prepareSeconds: prepareSeconds,
                                 beginSeconds: beginSeconds, finishSeconds: finishSeconds,
                                 totalSeconds: ProcessInfo.processInfo.systemUptime - batchStart, frames: frames))
        }
        let status = try await sink.status()
        return Report(format: formatName, screenLimit: screenLimit, intervalSeconds: interval,
                      batches: batches, totalStoredBytes: status.totalBytes, error: nil)
    }
}
