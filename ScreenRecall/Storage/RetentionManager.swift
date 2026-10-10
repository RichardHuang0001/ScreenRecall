import Foundation

struct RetentionPolicy: Sendable {
    let maxAge: TimeInterval
    let maximumBytes: Int64
    let highWatermarkBytes: Int64
    let lowWatermarkBytes: Int64
    let batchDeleteLimit: Int
    let minimumFreeBytes: Int64

    static let standard = RetentionPolicy(maxAge: 24 * 3600,
                                           maximumBytes: 2 * 1024 * 1024 * 1024,
                                           highWatermarkBytes: Int64(1.9 * Double(1024 * 1024 * 1024)),
                                           lowWatermarkBytes: Int64(1.7 * Double(1024 * 1024 * 1024)),
                                           batchDeleteLimit: 20,
                                           minimumFreeBytes: 5 * 1024 * 1024 * 1024)

    static func configured(hours: Int, maximumGiB: Int) -> RetentionPolicy {
        let hours = [6, 12, 24, 48].contains(hours) ? hours : 24
        let gib = [1, 2, 4].contains(maximumGiB) ? maximumGiB : 2
        let bytes = Int64(gib) * 1024 * 1024 * 1024
        return RetentionPolicy(maxAge: TimeInterval(hours * 3600), maximumBytes: bytes,
                               highWatermarkBytes: Int64(Double(bytes) * 0.95),
                               lowWatermarkBytes: Int64(Double(bytes) * 0.85), batchDeleteLimit: 20)
    }

    init(maxAge: TimeInterval, maximumBytes: Int64, highWatermarkBytes: Int64,
         lowWatermarkBytes: Int64, batchDeleteLimit: Int, minimumFreeBytes: Int64 = 5 * 1024 * 1024 * 1024) {
        precondition(maxAge > 0 && maximumBytes > 0 && lowWatermarkBytes < highWatermarkBytes &&
                     highWatermarkBytes <= maximumBytes && batchDeleteLimit > 0 && minimumFreeBytes >= 0)
        self.maxAge = maxAge
        self.maximumBytes = maximumBytes
        self.highWatermarkBytes = highWatermarkBytes
        self.lowWatermarkBytes = lowWatermarkBytes
        self.batchDeleteLimit = batchDeleteLimit
        self.minimumFreeBytes = minimumFreeBytes
    }
}

struct RetentionManager {
    let policy: RetentionPolicy

    func expiredIDs(repository: HistoryRepository, now: Date) throws -> [String] {
        try repository.expiredBatchIDs(cutoff: now.addingTimeInterval(-policy.maxAge), limit: policy.batchDeleteLimit)
    }

    func needsBudgetCleanup(repository: HistoryRepository) throws -> Bool {
        try repository.totalBytes() >= policy.highWatermarkBytes
    }
}
