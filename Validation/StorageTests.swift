import CoreGraphics
import Darwin
import Foundation
import SQLite3

private enum TestFailure: Error { case assertion(String) }

@main
enum StorageTests {
    static func main() async {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--kill-after-move" {
            do { try await killAfterMove(root: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { fputs("crash setup failed: \(error)\n", stderr); exit(2) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recover-after-kill" {
            do { try await recoverAfterKill(root: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { fputs("cross-process recovery failed: \(error)\n", stderr); exit(2) }
            return
        }
        do {
            try await basicCommitClearAndEpoch()
            try await recoverAfterMove()
            try await recoverAfterStagingRecord()
            try await recoverDatabaseTransactionFailure()
            try await recoverPartialBatch()
            try await recoverInterruptedDeletion()
            try await retentionAndMissingFile()
            try await boundedAuditDoesNotSkipMissingRows()
            try await cooperativeRetentionClearsBacklog()
            try await clearWhileImageIsInUse()
            try await capacityWatermarksAndProtectedAsset()
            try await orphanEncodingAndBatchStartRecovery()
            try await lowDiskStopsWrites()
            try await paginationAndMigration()
            try await clearRacesWithCommit()
            try singleWriterLock()
            print("PASS: commit, clear epoch/race, moved-file recovery, staged-file recovery, SQLite rollback recovery, partial batch, deletion recovery, age/capacity retention, asset lease and clear, low disk, pagination/migration, single writer, missing file, bounded audit and retention, orphan staging")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure.assertion(message) }
    }

    private static func paths() throws -> StoragePaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecall-StorageTests-\(UUID().uuidString)", isDirectory: true)
        return try StoragePaths(root: root)
    }

    private static func display(_ id: UInt32, order: Int) -> DisplayDescriptor {
        DisplayDescriptor(id: id, order: order, pixelWidth: 16, pixelHeight: 16, pointPixelScale: 1,
                          layoutX: Double(order * 100), layoutY: 20, layoutWidth: 16, layoutHeight: 16,
                          isMirrored: order == 1)
    }

    private static func asset(paths: StoragePaths, batchID: UUID, displayID: UInt32) throws -> CapturedAsset {
        let directory = paths.staging.appendingPathComponent(batchID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure.assertion("cannot create synthetic image")
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else { throw TestFailure.assertion("cannot render synthetic image") }
        let bytes = try ImageEncoder.writeJPEG(image, to: url)
        return CapturedAsset(displayID: displayID, stagingURL: url, width: 16, height: 16, byteCount: bytes,
                             format: "jpeg", captureStartedAt: Date(), captureEndedAt: Date())
    }

    private static func summary(id: UUID, started: Date, expected: Int, successes: [UInt32], status: CaptureBatchStatus) -> CaptureBatchSummary {
        CaptureBatchSummary(id: id, startedAt: started, endedAt: Date(), status: status, expectedCount: expected,
                            outcomes: successes.map { FrameOutcome(displayID: $0, succeeded: true, error: nil) }, errorSummary: nil)
    }

    private static func basicCommitClearAndEpoch() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sink = try PersistentCaptureSink(paths: paths)
        let id = UUID()
        let start = Date()
        try await sink.beginBatch(id, startedAt: start, displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: id, displayID: 1)
        try await sink.consume(image, batchID: id, generation: 0)
        try await sink.finish(summary(id: id, started: start, expected: 1, successes: [1], status: .complete), generation: 0)
        let before = try await sink.status()
        try expect(before.batchCount == 1 && before.totalBytes == image.byteCount, "commit totals wrong")
        try expect(try await sink.history().first?.status == "complete", "committed batch missing")
        let repository = try HistoryRepository(url: paths.database)
        let ready = try repository.assets(state: "ready")
        try expect(ready.count == 1, "ready asset missing")
        let frames = try await sink.frames(batchID: id.uuidString)
        try expect(frames.count == 1 && frames[0].layoutY == 20 && frames[0].layoutWidth == 16,
                   "display layout was not stored")
        let file = paths.root.appendingPathComponent(ready[0].relativePath)
        try expect(FileManager.default.fileExists(atPath: file.path), "committed file missing")
        let rootMode = (try FileManager.default.attributesOfItem(atPath: paths.root.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(rootMode == 0o700 && fileMode == 0o600, "private file permissions are wrong")
        let journal = try repository.db.query("PRAGMA journal_mode") { statement in String(cString: sqlite3_column_text(statement, 0)) }.first
        try expect(journal == "wal", "WAL mode not enabled")
        try await sink.clearHistory(minimumGeneration: 1)
        let after = try await sink.status()
        try expect(after.batchCount == 0 && after.totalBytes == 0 && after.epoch == before.epoch + 1, "clear history failed")
        try expect(!FileManager.default.fileExists(atPath: file.path), "clear left image file")
        let late = try asset(paths: paths, batchID: id, displayID: 1)
        do {
            try await sink.consume(late, batchID: id, generation: 0)
            throw TestFailure.assertion("late old-generation commit succeeded")
        } catch StorageError.staleGeneration { /* expected */ }
        await sink.discard(late)
    }

    private static func boundedAuditDoesNotSkipMissingRows() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sink = try PersistentCaptureSink(paths: paths)
        for _ in 0..<3 {
            let id = UUID()
            let start = Date()
            try await sink.beginBatch(id, startedAt: start, displays: [display(1, order: 0)], generation: 0)
            try await sink.consume(asset(paths: paths, batchID: id, displayID: 1), batchID: id, generation: 0)
            try await sink.finish(summary(id: id, started: start, expected: 1, successes: [1], status: .complete), generation: 0)
        }
        let repository = try HistoryRepository(url: paths.database)
        let ready = try repository.readyAssets(afterID: nil, limit: 10)
        try expect(ready.count == 3, "audit fixture missing assets")
        try FileManager.default.removeItem(at: paths.root.appendingPathComponent(ready[0].relativePath))
        for _ in 0..<3 { try expect(try await sink.auditNextReadyAssets(limit: 1) == 1, "audit skipped an asset") }
        try expect(try await sink.auditNextReadyAssets(limit: 1) == 0, "audit did not end its pass")
        try expect(try repository.assets(state: "missing").count == 1, "missing asset not marked")
    }

    private static func cooperativeRetentionClearsBacklog() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let policy = RetentionPolicy(maxAge: 60, maximumBytes: 1_000_000,
                                     highWatermarkBytes: 900_000, lowWatermarkBytes: 800_000,
                                     batchDeleteLimit: 1, minimumFreeBytes: 0)
        let sink = try PersistentCaptureSink(paths: paths)
        for _ in 0..<3 {
            let id = UUID()
            let start = Date()
            try await sink.beginBatch(id, startedAt: start, displays: [display(1, order: 0)], generation: 0)
            try await sink.consume(asset(paths: paths, batchID: id, displayID: 1), batchID: id, generation: 0)
            try await sink.finish(summary(id: id, started: start, expected: 1, successes: [1], status: .complete), generation: 0)
        }
        try expect((try await sink.status()).batchCount == 3, "retention fixture missing batches")
        await sink.updateRetentionPolicy(policy)
        try await sink.enforceRetentionCooperatively(now: Date().addingTimeInterval(120))
        try expect((try await sink.status()).batchCount == 0, "cooperative retention left expired batches")
    }

    private static func clearWhileImageIsInUse() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sink = try PersistentCaptureSink(paths: paths)
        let id = UUID()
        let start = Date()
        try await sink.beginBatch(id, startedAt: start, displays: [display(1, order: 0)], generation: 0)
        try await sink.consume(asset(paths: paths, batchID: id, displayID: 1), batchID: id, generation: 0)
        try await sink.finish(summary(id: id, started: start, expected: 1, successes: [1], status: .complete), generation: 0)
        let assetID = try HistoryRepository(url: paths.database).assets(state: "ready").first!.id
        let leased = try await sink.acquireAssetURL(assetID)
        try await sink.clearHistory(minimumGeneration: 1)
        try expect((try await sink.status()).batchCount == 0, "clear did not hide leased history")
        try expect(FileManager.default.fileExists(atPath: leased.path), "leased image was deleted early")
        await sink.releaseAsset(assetID)
        try expect(!FileManager.default.fileExists(atPath: leased.path), "leased image was not removed after release")
        try expect((try await sink.status()).totalBytes == 0, "clear left accounted bytes")
    }

    private static func recoverAfterMove() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        var sink: PersistentCaptureSink? = try PersistentCaptureSink(paths: paths, faultPoints: [.afterMove])
        try await sink!.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: id, displayID: 1)
        do {
            try await sink!.consume(image, batchID: id, generation: 0)
            throw TestFailure.assertion("after-move fault did not fire")
        } catch StorageError.injected(.afterMove) { /* simulated process exit */ }
        sink = nil
        let reopened = try PersistentCaptureSink(paths: paths)
        try await reopened.recover()
        let status = try await reopened.status()
        try expect(status.totalBytes == image.byteCount, "moved image not recovered")
        try expect(try HistoryRepository(url: paths.database).assets(state: "ready").count == 1, "moved asset not promoted")
        try await reopened.recover()
        try expect((try await reopened.status()).totalBytes == image.byteCount, "recovery is not idempotent")
    }

    private static func recoverAfterStagingRecord() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        var sink: PersistentCaptureSink? = try PersistentCaptureSink(paths: paths, faultPoints: [.afterStagingRecord])
        try await sink!.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: id, displayID: 1)
        do {
            try await sink!.consume(image, batchID: id, generation: 0)
            throw TestFailure.assertion("after-staging fault did not fire")
        } catch StorageError.injected(.afterStagingRecord) { /* expected */ }
        sink = nil
        let reopened = try PersistentCaptureSink(paths: paths)
        try await reopened.recover()
        try expect((try await reopened.status()).totalBytes == 0, "unmoved asset counted")
        try expect(!FileManager.default.fileExists(atPath: image.stagingURL.path), "orphan staging image remained")
        try expect(try HistoryRepository(url: paths.database).assets(state: "staging").isEmpty, "staging row remained")
    }

    private static func recoverDatabaseTransactionFailure() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        var sink: PersistentCaptureSink? = try PersistentCaptureSink(paths: paths)
        try await sink!.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: id, displayID: 1)
        let repository = try HistoryRepository(url: paths.database)
        try repository.db.execute("""
            CREATE TRIGGER fail_asset_ready BEFORE UPDATE OF state ON assets
            WHEN NEW.state='ready' BEGIN SELECT RAISE(ABORT,'injected database failure'); END
            """)
        do {
            try await sink!.consume(image, batchID: id, generation: 0)
            throw TestFailure.assertion("SQLite trigger did not abort commit")
        } catch DatabaseError.sqlite { /* expected */ }
        try expect(try repository.assets(state: "staging").count == 1, "transaction rollback lost recovery record")
        try repository.db.execute("DROP TRIGGER fail_asset_ready")
        sink = nil
        let reopened = try PersistentCaptureSink(paths: paths)
        try await reopened.recover()
        try expect((try await reopened.status()).totalBytes == image.byteCount, "SQLite failure recovery did not promote moved file")
    }

    private static func recoverPartialBatch() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        var sink: PersistentCaptureSink? = try PersistentCaptureSink(paths: paths)
        try await sink!.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0), display(2, order: 1)], generation: 0)
        let first = try asset(paths: paths, batchID: id, displayID: 1)
        try await sink!.consume(first, batchID: id, generation: 0)
        sink = nil // Termination before the second screen.
        let reopened = try PersistentCaptureSink(paths: paths)
        try await reopened.recover()
        let history = try await reopened.history()
        try expect(history.count == 1 && history[0].successCount == 1 && history[0].status == "interrupted", "partial crash recovery lost first screen")
    }

    private static func recoverInterruptedDeletion() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var sink: PersistentCaptureSink? = try PersistentCaptureSink(paths: paths, faultPoints: [.afterDeleteFiles])
        let id = UUID()
        try await sink!.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: id, displayID: 1)
        try await sink!.consume(image, batchID: id, generation: 0)
        try await sink!.finish(summary(id: id, started: Date(), expected: 1, successes: [1], status: .complete), generation: 0)
        do {
            try await sink!.clearHistory(minimumGeneration: 1)
            throw TestFailure.assertion("deletion fault did not fire")
        } catch StorageError.injected(.afterDeleteFiles) { /* expected */ }
        sink = nil
        let reopened = try PersistentCaptureSink(paths: paths)
        try await reopened.recover()
        try expect((try await reopened.status()).batchCount == 0, "deleting batch not finalized")
        try expect((try await reopened.status()).totalBytes == 0, "total bytes not repaired after interrupted deletion")
    }

    private static func retentionAndMissingFile() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let policy = RetentionPolicy(maxAge: 60, maximumBytes: 1_000_000, highWatermarkBytes: 900_000,
                                     lowWatermarkBytes: 700_000, batchDeleteLimit: 10)
        let sink = try PersistentCaptureSink(paths: paths, policy: policy)
        let oldID = UUID()
        let oldDate = Date().addingTimeInterval(-3600)
        try await sink.beginBatch(oldID, startedAt: oldDate, displays: [display(1, order: 0)], generation: 0)
        let oldAsset = try asset(paths: paths, batchID: oldID, displayID: 1)
        try await sink.consume(oldAsset, batchID: oldID, generation: 0)
        try await sink.finish(summary(id: oldID, started: oldDate, expected: 1, successes: [1], status: .complete), generation: 0)
        try expect((try await sink.status()).batchCount == 0, "time retention did not remove old batch")

        let newID = UUID()
        let now = Date()
        try await sink.beginBatch(newID, startedAt: now, displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: newID, displayID: 1)
        try await sink.consume(image, batchID: newID, generation: 0)
        try await sink.finish(summary(id: newID, started: now, expected: 1, successes: [1], status: .complete), generation: 0)
        let repository = try HistoryRepository(url: paths.database)
        let ready = try repository.assets(state: "ready").first!
        try FileManager.default.removeItem(at: paths.root.appendingPathComponent(ready.relativePath))
        _ = try await sink.auditReadyAssets(limit: 10, offset: 0)
        try expect((try await sink.status()).totalBytes == 0, "missing file not removed from byte total")
        try expect(try repository.assets(state: "missing").count == 1, "missing asset state not recorded")
    }

    private static func capacityWatermarksAndProtectedAsset() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sizeProbe = try asset(paths: paths, batchID: UUID(), displayID: 99)
        let bytes = sizeProbe.byteCount
        try FileManager.default.removeItem(at: sizeProbe.stagingURL.deletingLastPathComponent())
        let policy = RetentionPolicy(maxAge: 3600, maximumBytes: bytes * 3,
                                     highWatermarkBytes: bytes * 2, lowWatermarkBytes: bytes,
                                     batchDeleteLimit: 2)
        let sink = try PersistentCaptureSink(paths: paths, policy: policy)
        var latestID = UUID()
        for index in 0..<3 {
            let id = UUID()
            latestID = id
            let start = Date().addingTimeInterval(Double(index))
            try await sink.beginBatch(id, startedAt: start, displays: [display(1, order: 0)], generation: 0)
            let image = try asset(paths: paths, batchID: id, displayID: 1)
            try await sink.consume(image, batchID: id, generation: 0)
            try await sink.finish(summary(id: id, started: start, expected: 1, successes: [1], status: .complete), generation: 0)
        }
        let status = try await sink.status()
        try expect(status.totalBytes <= bytes && status.batchCount == 1, "capacity watermark did not trim to low level")
        try expect((try await sink.history()).first?.id == latestID.uuidString, "capacity cleanup removed newest batch")

        let repository = try HistoryRepository(url: paths.database)
        let assetID = try repository.assets(state: "ready").first!.id
        _ = try await sink.acquireAssetURL(assetID)
        do {
            try await sink.enforceRetention(now: Date().addingTimeInterval(7200))
            throw TestFailure.assertion("protected image was deleted")
        } catch StorageError.protectedAsset { /* expected */ }
        await sink.releaseAsset(assetID)
        try await sink.enforceRetention(now: Date().addingTimeInterval(7200))
        try expect((try await sink.status()).batchCount == 0, "deletion did not resume after lease release")
    }

    private static func orphanEncodingAndBatchStartRecovery() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        var sink: PersistentCaptureSink? = try PersistentCaptureSink(paths: paths, faultPoints: [.afterBatchInsert])
        do {
            try await sink!.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
            throw TestFailure.assertion("after-batch fault did not fire")
        } catch StorageError.injected(.afterBatchInsert) { /* expected */ }
        let folder = paths.staging.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let incomplete = folder.appendingPathComponent("partial.jpg")
        try Data([0xff, 0xd8, 0x00]).write(to: incomplete)
        sink = nil
        let reopened = try PersistentCaptureSink(paths: paths)
        try await reopened.recover()
        try expect(!FileManager.default.fileExists(atPath: incomplete.path), "half-encoded orphan remained")
        try expect((try await reopened.history()).first?.status == "interrupted", "batch-start crash not marked interrupted")
    }

    private static func lowDiskStopsWrites() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let policy = RetentionPolicy(maxAge: 3600, maximumBytes: 1000, highWatermarkBytes: 900,
                                     lowWatermarkBytes: 700, batchDeleteLimit: 10, minimumFreeBytes: 500)
        let sink = try PersistentCaptureSink(paths: paths, policy: policy, availableSpace: { 0 })
        do {
            try await sink.beginBatch(UUID(), startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
            throw TestFailure.assertion("low disk did not stop new batch")
        } catch StorageError.insufficientDiskSpace { /* expected */ }
        try expect((try await sink.status()).batchCount == 0, "low disk created a batch")
    }

    private static func paginationAndMigration() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sink = try PersistentCaptureSink(paths: paths)
        let base = Date().addingTimeInterval(-180)
        var ids: [UUID] = []
        for offset in 0..<3 {
            let id = UUID()
            ids.append(id)
            let start = base.addingTimeInterval(Double(offset * 60))
            try await sink.beginBatch(id, startedAt: start, displays: [display(1, order: 0)], generation: 0)
            try await sink.finish(summary(id: id, started: start, expected: 1, successes: [], status: .failed), generation: 0)
        }
        let first = try await sink.history(limit: 2)
        try expect(first.map(\.id) == [ids[2].uuidString, ids[1].uuidString], "history sort order wrong")
        let second = try await sink.history(limit: 2, before: first[1].cursor)
        try expect(second.map(\.id) == [ids[0].uuidString], "history page cursor wrong")
        let duplicateTime = Date()
        let a = UUID()
        let b = UUID()
        for id in [a, b] {
            try await sink.beginBatch(id, startedAt: duplicateTime, displays: [display(1, order: 0)], generation: 0)
            try await sink.finish(summary(id: id, started: duplicateTime, expected: 1, successes: [], status: .failed), generation: 0)
        }
        let sameTimeFirst = try await sink.history(limit: 1)
        let sameTimeSecond = try await sink.history(limit: 1, before: sameTimeFirst[0].cursor)
        try expect(sameTimeFirst[0].startedAt == sameTimeSecond[0].startedAt && sameTimeFirst[0].id != sameTimeSecond[0].id,
                   "same-timestamp pagination lost a batch")
        let database = try SQLiteDatabase(url: paths.database)
        try expect(try database.scalarInt("PRAGMA user_version") == 2, "schema version missing")
        let reopenedRepository = try HistoryRepository(url: paths.database)
        try expect((try reopenedRepository.history(limit: 10)).count == 5, "migration reopen changed history")

        let legacyURL = paths.root.appendingPathComponent("legacy-v1.sqlite")
        var legacyHandle: OpaquePointer?
        guard sqlite3_open(legacyURL.path, &legacyHandle) == SQLITE_OK, let legacyHandle else {
            throw TestFailure.assertion("cannot create v1 fixture")
        }
        guard sqlite3_exec(legacyHandle, "CREATE TABLE frames(batch_id TEXT); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(legacyHandle)
            throw TestFailure.assertion("cannot initialize v1 fixture")
        }
        sqlite3_close(legacyHandle)
        let migrated = try SQLiteDatabase(url: legacyURL)
        try expect(try migrated.scalarInt("PRAGMA user_version") == 2, "v1 to v2 migration failed")
        let columns = try migrated.query("PRAGMA table_info(frames)") { statement in
            String(cString: sqlite3_column_text(statement, 1))
        }
        try expect(columns.contains("layout_x") && columns.contains("is_mirrored"), "v2 columns missing")
    }

    private static func clearRacesWithCommit() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sink = try PersistentCaptureSink(paths: paths)
        let id = UUID()
        try await sink.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: id, displayID: 1)
        let commit = Task { try? await sink.consume(image, batchID: id, generation: 0) }
        let clear = Task { try await sink.clearHistory(minimumGeneration: 1) }
        await commit.value
        try await clear.value
        await sink.discard(image)
        let status = try await sink.status()
        try expect(status.batchCount == 0 && status.totalBytes == 0, "clear/commit race resurrected history")
        do {
            try await sink.beginBatch(UUID(), startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
            throw TestFailure.assertion("old generation began after clear")
        } catch StorageError.staleGeneration { /* expected */ }
    }

    private static func killAfterMove(root: URL) async throws {
        let paths = try StoragePaths(root: root)
        let sink = try PersistentCaptureSink(paths: paths, faultPoints: [.afterMove])
        let id = UUID()
        try await sink.beginBatch(id, startedAt: Date(), displays: [display(1, order: 0)], generation: 0)
        let image = try asset(paths: paths, batchID: id, displayID: 1)
        do { try await sink.consume(image, batchID: id, generation: 0) }
        catch StorageError.injected(.afterMove) {
            fflush(stdout)
            kill(getpid(), SIGKILL)
            exit(3)
        }
        throw TestFailure.assertion("crash checkpoint was not reached")
    }

    private static func recoverAfterKill(root: URL) async throws {
        let paths = try StoragePaths(root: root)
        let sink = try PersistentCaptureSink(paths: paths)
        try await sink.recover()
        let status = try await sink.status()
        let repository = try HistoryRepository(url: paths.database)
        let ready = try repository.assets(state: "ready")
        try expect(status.batchCount == 1 && status.totalBytes > 0 && ready.count == 1,
                   "SIGKILL recovery did not promote moved image")
        try await sink.clearHistory(minimumGeneration: 1)
        try expect((try await sink.status()).totalBytes == 0, "post-recovery cleanup failed")
        print("PASS: SIGKILL after atomic move recovered on new process")
    }

    private static func singleWriterLock() throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var first: PersistentCaptureSink? = try PersistentCaptureSink(paths: paths)
        do {
            _ = try PersistentCaptureSink(paths: paths)
            throw TestFailure.assertion("second writer opened the same history directory")
        } catch StorageLockError.alreadyOpen { /* expected */ }
        try expect(first != nil, "first writer released unexpectedly")
        first = nil
        _ = try PersistentCaptureSink(paths: paths)
    }
}
