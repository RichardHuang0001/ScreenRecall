import Foundation

/// Phase 1 验证接收端：仅保留少量不含图片内容的批次元数据。
actor EphemeralCaptureSink: CaptureConsuming {
    private(set) var summaries: [CaptureBatchSummary] = []

    func beginBatch(_ batchID: UUID, startedAt: Date, displays: [DisplayDescriptor], generation: UInt64) {}

    func consume(_ asset: CapturedAsset, batchID: UUID, generation: UInt64) throws {
        try FileManager.default.removeItem(at: asset.stagingURL)
    }

    func discard(_ asset: CapturedAsset) {
        try? FileManager.default.removeItem(at: asset.stagingURL)
    }

    func recordFailure(display: DisplayDescriptor, batchID: UUID, generation: UInt64, message: String) {}

    func finish(_ summary: CaptureBatchSummary, generation: UInt64) {
        summaries.append(summary)
        if summaries.count > 64 { summaries.removeFirst(summaries.count - 64) }
    }

    func clearHistory(minimumGeneration: UInt64) { summaries.removeAll() }

    func invalidatePreviousGeneration(_ minimumGeneration: UInt64, capturedSince: Date) {
        summaries.removeAll { $0.endedAt >= capturedSince }
    }

    func recentSummaries() -> [CaptureBatchSummary] { summaries }
}
