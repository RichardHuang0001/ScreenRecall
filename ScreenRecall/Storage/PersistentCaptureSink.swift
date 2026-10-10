import Foundation

enum StorageFaultPoint: Hashable, Sendable {
    case afterBatchInsert, afterStagingRecord, afterMove, afterMetadataCommit
    case afterDeleteFiles, afterClearMark
}

enum StorageError: LocalizedError {
    case injected(StorageFaultPoint), staleGeneration, protectedAsset, cleanupIncomplete
    case insufficientDiskSpace, freeSpaceUnknown
    var errorDescription: String? {
        switch self {
        case .injected(let point): "故障注入：\(point)"
        case .staleGeneration: "旧采集代次不能写入历史"
        case .protectedAsset: "图片正在预览或导出，暂不能删除"
        case .cleanupIncomplete: "历史清理尚未完成"
        case .insufficientDiskSpace: "磁盘安全余量不足，已暂停截图"
        case .freeSpaceUnknown: "无法确认磁盘可用空间，已暂停截图"
        }
    }
}

struct StorageStatus: Sendable {
    let batchCount: Int
    let totalBytes: Int64
    let oldestAvailableAt: Date?
    let epoch: Int64
}

/// SQLite 与文件提交的唯一串行执行通道。
actor PersistentCaptureSink: CaptureConsuming {
    let paths: StoragePaths
    private let writerLock: StorageWriterLock
    private let repository: HistoryRepository
    private let fileStore: AssetFileStore
    private var retention: RetentionManager
    private var minimumGeneration: UInt64 = 0
    private var recovered = false
    private var faultPoints: Set<StorageFaultPoint>
    private var protectedAssets: [String: Int] = [:]
    private var auditCursor: String?
    private var budgetCleanupActive = false
    private let availableSpace: @Sendable () -> Int64?

    init(paths: StoragePaths, policy: RetentionPolicy = .standard, faultPoints: Set<StorageFaultPoint> = [],
         availableSpace: (@Sendable () -> Int64?)? = nil) throws {
        self.paths = paths
        writerLock = try StorageWriterLock(root: paths.root)
        repository = try HistoryRepository(url: paths.database)
        fileStore = AssetFileStore(paths: paths)
        retention = RetentionManager(policy: policy)
        self.faultPoints = faultPoints
        self.availableSpace = availableSpace ?? {
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: paths.root.path)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        }
    }

    func recover() throws {
        guard !recovered else { return }
        try drainDeletingBatches()
        while true {
            let staged = try repository.assets(state: "staging", limit: 100)
            if staged.isEmpty { break }
            for asset in staged {
                let final = try fileStore.resolve(asset.relativePath)
                let source = try fileStore.resolve(asset.stagingPath)
                if fileStore.exists(final) {
                    do {
                        try fileStore.verify(final, width: asset.width, height: asset.height, bytes: asset.byteCount)
                        try repository.promoteAsset(id: asset.id)
                        try fileStore.removeIfExists(source)
                        continue
                    } catch { /* Invalid or stale file is removed below. */ }
                }
                try fileStore.removeIfExists(final)
                try fileStore.pruneEmptyAssetParents(of: final)
                try fileStore.removeIfExists(source)
                try repository.removeUncommittedAsset(asset, reason: "incomplete file commit recovered")
            }
        }
        try repository.finishInterruptedBatches()
        try cleanupOrphanStaging()
        _ = try auditReadyAssets(limit: 100, offset: 0)
        recovered = true
    }

    func beginBatch(_ batchID: UUID, startedAt: Date, displays: [DisplayDescriptor], generation: UInt64) throws {
        try recover()
        guard generation >= minimumGeneration else { throw StorageError.staleGeneration }
        try ensureDiskHeadroom()
        try repository.beginBatch(id: batchID, startedAt: startedAt, displays: displays, generation: generation)
        try inject(.afterBatchInsert)
    }

    func consume(_ asset: CapturedAsset, batchID: UUID, generation: UInt64) throws {
        try recover()
        guard generation >= minimumGeneration else { throw StorageError.staleGeneration }
        try ensureDiskHeadroom()
        let stagingPath = try fileStore.stagingRelativePath(asset.stagingURL)
        try fileStore.verify(asset.stagingURL, width: asset.width, height: asset.height, bytes: asset.byteCount)
        let order = try repository.displayOrder(batchID: batchID, displayID: asset.displayID)
        let assetID = UUID()
        let relativePath = fileStore.relativePath(assetID: assetID, date: asset.captureStartedAt, format: asset.format)
        try repository.insertStagedAsset(id: assetID, batchID: batchID, displayOrder: order, asset: asset,
                                         relativePath: relativePath, stagingPath: stagingPath)
        try inject(.afterStagingRecord)
        try fileStore.moveStaged(asset.stagingURL, to: relativePath)
        try inject(.afterMove)
        guard generation >= minimumGeneration else { throw StorageError.staleGeneration }
        try repository.promoteAsset(id: assetID.uuidString)
        try inject(.afterMetadataCommit)
    }

    func recordFailure(display: DisplayDescriptor, batchID: UUID, generation: UInt64, message: String) throws {
        try recover()
        guard generation >= minimumGeneration else { return }
        try repository.recordFailure(display: display, batchID: batchID, message: message)
    }

    func discard(_ asset: CapturedAsset) {
        // 若已完成原子移动，原暂存路径不存在；恢复器负责处理数据库中留存的 staging 行。
        try? fileStore.removeIfExists(asset.stagingURL)
    }

    func finish(_ summary: CaptureBatchSummary, generation: UInt64) throws {
        try recover()
        guard generation >= minimumGeneration else { return }
        try repository.finishBatch(summary)
        do { _ = try enforceRetentionStep(now: Date()) }
        catch StorageError.protectedAsset {
            // The batch is committed. A preview/export lease defers deletion, not capture.
            // releaseAsset drains the marked rows once the last lease is released.
        }
    }

    func invalidatePreviousGeneration(_ generation: UInt64, capturedSince: Date) throws {
        minimumGeneration = max(minimumGeneration, generation)
        try recover()
        try repository.markBatchesOverlappingPrivacyChange(capturedSince)
        try drainDeletingBatches()
    }

    func clearHistory(minimumGeneration: UInt64) throws {
        try recover()
        self.minimumGeneration = max(self.minimumGeneration, minimumGeneration)
        _ = try repository.advanceEpochAndMarkAllDeleting()
        try inject(.afterClearMark)
        do { try drainDeletingBatches() }
        catch StorageError.protectedAsset { /* 文件使用结束后继续删除。 */ }
    }

    func status() throws -> StorageStatus {
        try recover()
        return StorageStatus(batchCount: try repository.batchCount(), totalBytes: try repository.totalBytes(),
                             oldestAvailableAt: try repository.oldestAvailableDate(), epoch: try repository.currentEpoch())
    }

    func latestSuccessfulDate() throws -> Date? {
        try recover()
        return try repository.latestSuccessfulDate()
    }

    func history(limit: Int = 50, before: HistoryCursor? = nil) throws -> [StoredBatch] {
        try recover()
        return try repository.history(limit: max(1, min(limit, 100)), before: before)
    }

    func frames(batchID: String) throws -> [StoredFrame] {
        try recover()
        return try repository.frames(batchID: batchID)
    }

    func enforceRetention(now: Date) throws {
        try recover()
        try drainDeletingBatches()
        while try enforceRetentionStep(now: now) {}
    }

    /// 长时间休眠后的大量清理在每轮之间让出 actor，避免独占下一次采集。
    func enforceRetentionCooperatively(now: Date) async throws {
        try recover()
        while !Task.isCancelled {
            guard try enforceRetentionStep(now: now) else { return }
            await Task.yield()
        }
    }

    @discardableResult
    private func enforceRetentionStep(now: Date) throws -> Bool {
        // Do not hide more history while an earlier deletion is waiting on a reader.
        do { try drainDeletingBatches() }
        catch StorageError.protectedAsset { return false }
        let expired = try retention.expiredIDs(repository: repository, now: now)
        if !expired.isEmpty {
            try repository.markDeleting(expired)
            try drainDeletingBatches()
            return true
        }
        let bytes = try repository.totalBytes()
        if bytes >= retention.policy.highWatermarkBytes { budgetCleanupActive = true }
        guard budgetCleanupActive, bytes > retention.policy.lowWatermarkBytes else {
            budgetCleanupActive = false
            return false
        }
        let oldest = try repository.oldestBatchIDs(limit: retention.policy.batchDeleteLimit)
        guard !oldest.isEmpty else { return false }
        try repository.markDeleting(oldest)
        try drainDeletingBatches()
        return true
    }

    func acquireAssetURL(_ assetID: String) throws -> URL {
        try recover()
        guard let asset = try repository.asset(id: assetID), asset.state == "ready" else { throw AssetStoreError.invalidFile }
        let url = try fileStore.resolve(asset.relativePath)
        // 大图解码由界面专用后台任务处理，不能在采集/存储 actor 上执行。
        try fileStore.verifyFileSize(url, bytes: asset.byteCount)
        protectedAssets[assetID, default: 0] += 1
        return url
    }

    func updateRetentionPolicy(_ policy: RetentionPolicy) {
        retention = RetentionManager(policy: policy)
        budgetCleanupActive = false
    }

    func releaseAsset(_ assetID: String) {
        let count = protectedAssets[assetID, default: 0]
        if count <= 1 { protectedAssets.removeValue(forKey: assetID) }
        else { protectedAssets[assetID] = count - 1 }
        if protectedAssets.isEmpty { try? drainDeletingBatches() }
    }

    @discardableResult
    func auditReadyAssets(limit: Int, offset: Int) throws -> Int {
        let assets = try repository.readyAssets(limit: limit, offset: offset)
        for asset in assets {
            if protectedAssets[asset.id] != nil { continue }
            let url = try fileStore.resolve(asset.relativePath)
            do { try fileStore.verify(url, width: asset.width, height: asset.height, bytes: asset.byteCount) }
            catch {
                try fileStore.removeIfExists(url)
                try repository.markMissing(asset)
            }
        }
        return assets.count
    }

    /// 每次只核对少量文件，使用稳定的 ID 游标，避免删除缺失行时 OFFSET 跳项。
    @discardableResult
    func auditNextReadyAssets(limit: Int = 2) throws -> Int {
        try recover()
        let assets = try repository.readyAssets(afterID: auditCursor, limit: max(1, min(limit, 8)))
        if assets.isEmpty {
            auditCursor = nil
            return 0
        }
        for asset in assets {
            auditCursor = asset.id
            if protectedAssets[asset.id] != nil { continue }
            let url = try fileStore.resolve(asset.relativePath)
            do { try fileStore.verify(url, width: asset.width, height: asset.height, bytes: asset.byteCount) }
            catch {
                try fileStore.removeIfExists(url)
                try repository.markMissing(asset)
            }
        }
        return assets.count
    }

    private func drainDeletingBatches() throws {
        while let batchID = try repository.nextDeletingBatch() {
            let assets = try repository.assets(batchID: batchID)
            guard !assets.contains(where: { protectedAssets[$0.id] != nil }) else { throw StorageError.protectedAsset }
            for asset in assets {
                let assetURL = try fileStore.resolve(asset.relativePath)
                try fileStore.removeIfExists(assetURL)
                try fileStore.pruneEmptyAssetParents(of: assetURL)
                try fileStore.removeIfExists(fileStore.resolve(asset.stagingPath))
            }
            try inject(.afterDeleteFiles)
            try repository.finalizeDelete(batchID: batchID)
        }
    }

    private func cleanupOrphanStaging() throws {
        // 仅检查小型 staging 区，不扫描历史 assets 目录。
        let referenced = Set(try repository.assets(state: "staging", limit: 100).map(\.stagingPath))
        let folders = try FileManager.default.contentsOfDirectory(at: paths.staging, includingPropertiesForKeys: nil)
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let relative = try? fileStore.stagingRelativePath(file)
                if relative == nil || !referenced.contains(relative!) { try fileStore.removeIfExists(file) }
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try fileStore.removeIfExists(folder)
            }
        }
    }

    private func inject(_ point: StorageFaultPoint) throws {
        if faultPoints.remove(point) != nil { throw StorageError.injected(point) }
    }

    private func ensureDiskHeadroom() throws {
        guard let free = availableSpace() else { throw StorageError.freeSpaceUnknown }
        guard free < retention.policy.minimumFreeBytes else { return }
        try enforceRetention(now: Date())
        guard let afterCleanup = availableSpace() else { throw StorageError.freeSpaceUnknown }
        guard afterCleanup >= retention.policy.minimumFreeBytes else { throw StorageError.insufficientDiskSpace }
    }
}
