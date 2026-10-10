import Foundation
import SQLite3

enum HistoryError: LocalizedError {
    case staleGeneration, missingBatch, invalidTransition
    var errorDescription: String? {
        switch self {
        case .staleGeneration: "旧采集批次已失效"
        case .missingBatch: "采集批次不存在"
        case .invalidTransition: "存储状态转换无效"
        }
    }
}

struct StoredBatch: Sendable {
    let id: String
    let startedAt: Date
    let expectedCount: Int
    let successCount: Int
    let status: String
    var cursor: HistoryCursor { HistoryCursor(startedAt: startedAt, id: id) }
}

struct HistoryCursor: Sendable {
    let startedAt: Date
    let id: String
}

struct StoredAsset: Sendable {
    let id: String
    let batchID: String
    let displayOrder: Int
    let relativePath: String
    let stagingPath: String
    let byteCount: Int64
    let width: Int
    let height: Int
    let state: String
    let accounted: Bool
    let epoch: Int64
    let captureStartedAt: Date
    let captureEndedAt: Date
}

struct StoredFrame: Sendable {
    let displayOrder: Int
    let displayID: UInt32
    let status: String
    let assetID: String?
    let error: String?
    let layoutX: Double
    let layoutY: Double
    let layoutWidth: Double
    let layoutHeight: Double
    let isMirrored: Bool
}

/// 短事务与索引查询；仅由持久化 actor 调用。
final class HistoryRepository {
    let db: SQLiteDatabase

    init(url: URL) throws { db = try SQLiteDatabase(url: url) }

    func currentEpoch() throws -> Int64 { try db.scalarInt("SELECT epoch FROM settings WHERE id=1") }
    func totalBytes() throws -> Int64 { try db.scalarInt("SELECT total_bytes FROM settings WHERE id=1") }
    func batchCount() throws -> Int { Int(try db.scalarInt("SELECT COUNT(*) FROM batches WHERE status != 'deleting'")) }

    func latestSuccessfulDate() throws -> Date? {
        try db.query("SELECT MAX(started_at) FROM batches WHERE status!='deleting' AND success_count>0") {
            sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }.first ?? nil
    }

    func beginBatch(id: UUID, startedAt: Date, displays: [DisplayDescriptor], generation: UInt64) throws {
        try db.transaction {
            let epoch = try currentEpoch()
            try db.execute("INSERT INTO batches(id,scheduled_at,started_at,expected_count,status,epoch,generation) VALUES(?,?,?,?,?,?,?)",
                           [.text(id.uuidString), .real(startedAt.timeIntervalSince1970), .real(startedAt.timeIntervalSince1970),
                            .integer(Int64(displays.count)), .text("capturing"), .integer(epoch), .integer(Int64(generation))])
            for display in displays {
                try db.execute("INSERT INTO frames(batch_id,display_order,display_id,pixel_width,pixel_height,point_pixel_scale,status,layout_x,layout_y,layout_width,layout_height,is_mirrored) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                               [.text(id.uuidString), .integer(Int64(display.order)), .integer(Int64(display.id)),
                                .integer(Int64(display.pixelWidth)), .integer(Int64(display.pixelHeight)),
                                .real(display.pointPixelScale), .text("pending"),
                                .real(display.layoutX), .real(display.layoutY), .real(display.layoutWidth), .real(display.layoutHeight),
                                .integer(display.isMirrored ? 1 : 0)])
            }
        }
    }

    func displayOrder(batchID: UUID, displayID: UInt32) throws -> Int {
        let rows = try db.query("SELECT display_order FROM frames WHERE batch_id=? AND display_id=? AND status='pending' LIMIT 1",
                                [.text(batchID.uuidString), .integer(Int64(displayID))]) { Int(sqlite3_column_int64($0, 0)) }
        guard let order = rows.first else { throw HistoryError.invalidTransition }
        return order
    }

    func insertStagedAsset(id: UUID, batchID: UUID, displayOrder: Int, asset: CapturedAsset,
                           relativePath: String, stagingPath: String) throws {
        try db.transaction {
            let epoch = try currentEpoch()
            let rows = try db.query("SELECT epoch FROM batches WHERE id=? AND status='capturing'", [.text(batchID.uuidString)]) { sqlite3_column_int64($0, 0) }
            guard rows.first == epoch else { throw HistoryError.staleGeneration }
            try db.execute("""
                INSERT INTO assets(id,batch_id,display_order,relative_path,staging_path,format,byte_count,pixel_width,pixel_height,encoding_version,created_at,capture_started_at,capture_ended_at,state,epoch)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(id.uuidString), .text(batchID.uuidString), .integer(Int64(displayOrder)), .text(relativePath), .text(stagingPath),
                      .text(asset.format), .integer(asset.byteCount), .integer(Int64(asset.width)), .integer(Int64(asset.height)),
                      .integer(1), .real(Date().timeIntervalSince1970), .real(asset.captureStartedAt.timeIntervalSince1970),
                      .real(asset.captureEndedAt.timeIntervalSince1970), .text("staging"), .integer(epoch)])
        }
    }

    func promoteAsset(id: String) throws {
        try db.transaction {
            guard let asset = try asset(id: id), asset.state == "staging" else { throw HistoryError.invalidTransition }
            let epoch = try currentEpoch()
            let batchEpoch = try db.query("SELECT epoch FROM batches WHERE id=? AND status!='deleting'", [.text(asset.batchID)]) { sqlite3_column_int64($0, 0) }.first
            guard asset.epoch == epoch, batchEpoch == epoch else { throw HistoryError.staleGeneration }
            try db.execute("UPDATE assets SET state='ready',accounted=1 WHERE id=? AND state='staging'", [.text(id)])
            guard db.changes() == 1 else { throw HistoryError.invalidTransition }
            try db.execute("""
                UPDATE frames SET status='success',asset_id=?,capture_started_at=?,capture_ended_at=?,pixel_width=?,pixel_height=?
                WHERE batch_id=? AND display_order=? AND status IN ('pending','failed','interrupted')
                """, [.text(id), .real(asset.captureStartedAt.timeIntervalSince1970), .real(asset.captureEndedAt.timeIntervalSince1970),
                      .integer(Int64(asset.width)), .integer(Int64(asset.height)), .text(asset.batchID), .integer(Int64(asset.displayOrder))])
            guard db.changes() == 1 else { throw HistoryError.invalidTransition }
            try db.execute("""
                UPDATE batches SET success_count=success_count+1,
                  status=CASE WHEN status IN ('failed','partial') AND success_count+1=expected_count THEN 'complete'
                              WHEN status='failed' THEN 'partial' ELSE status END
                WHERE id=?
                """, [.text(asset.batchID)])
            try db.execute("UPDATE settings SET total_bytes=total_bytes+? WHERE id=1", [.integer(asset.byteCount)])
        }
    }

    func recordFailure(display: DisplayDescriptor, batchID: UUID, message: String) throws {
        try db.execute("UPDATE frames SET status='failed',error=? WHERE batch_id=? AND display_order=? AND status='pending'",
                       [.text(message), .text(batchID.uuidString), .integer(Int64(display.order))])
    }

    func finishBatch(_ summary: CaptureBatchSummary) throws {
        try db.transaction {
            let epoch = try currentEpoch()
            let batchEpoch = try db.query("SELECT epoch FROM batches WHERE id=? AND status='capturing'", [.text(summary.id.uuidString)]) { sqlite3_column_int64($0, 0) }.first
            guard batchEpoch == epoch else { return }
            try db.execute("UPDATE frames SET status='interrupted' WHERE batch_id=? AND status='pending'", [.text(summary.id.uuidString)])
            let successes = try db.scalarInt("SELECT COUNT(*) FROM frames WHERE batch_id=? AND status='success'", [.text(summary.id.uuidString)])
            let status = summary.status == .complete && successes != summary.expectedCount ? CaptureBatchStatus.partial.rawValue : summary.status.rawValue
            try db.execute("UPDATE batches SET ended_at=?,success_count=?,status=?,error_summary=? WHERE id=?",
                           [.real(summary.endedAt.timeIntervalSince1970), .integer(successes), .text(status),
                            summary.errorSummary.map(SQLValue.text) ?? .null, .text(summary.id.uuidString)])
        }
    }

    func asset(id: String) throws -> StoredAsset? {
        try db.query("SELECT id,batch_id,display_order,relative_path,staging_path,byte_count,pixel_width,pixel_height,state,accounted,epoch,capture_started_at,capture_ended_at FROM assets WHERE id=?",
                     [.text(id)], map: Self.mapAsset).first
    }

    func assets(state: String, limit: Int = 100) throws -> [StoredAsset] {
        try db.query("SELECT id,batch_id,display_order,relative_path,staging_path,byte_count,pixel_width,pixel_height,state,accounted,epoch,capture_started_at,capture_ended_at FROM assets WHERE state=? ORDER BY created_at,id LIMIT ?",
                     [.text(state), .integer(Int64(limit))], map: Self.mapAsset)
    }

    func readyAssets(limit: Int = 100, offset: Int = 0) throws -> [StoredAsset] {
        try db.query("SELECT id,batch_id,display_order,relative_path,staging_path,byte_count,pixel_width,pixel_height,state,accounted,epoch,capture_started_at,capture_ended_at FROM assets WHERE state='ready' ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",
                     [.integer(Int64(limit)), .integer(Int64(offset))], map: Self.mapAsset)
    }

    func readyAssets(afterID: String?, limit: Int) throws -> [StoredAsset] {
        try db.query("SELECT id,batch_id,display_order,relative_path,staging_path,byte_count,pixel_width,pixel_height,state,accounted,epoch,capture_started_at,capture_ended_at FROM assets WHERE state='ready' AND id>? ORDER BY id LIMIT ?",
                     [.text(afterID ?? ""), .integer(Int64(limit))], map: Self.mapAsset)
    }

    func assets(batchID: String) throws -> [StoredAsset] {
        try db.query("SELECT id,batch_id,display_order,relative_path,staging_path,byte_count,pixel_width,pixel_height,state,accounted,epoch,capture_started_at,capture_ended_at FROM assets WHERE batch_id=?",
                     [.text(batchID)], map: Self.mapAsset)
    }

    func removeUncommittedAsset(_ asset: StoredAsset, reason: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM assets WHERE id=? AND state='staging'", [.text(asset.id)])
            try db.execute("UPDATE frames SET status='failed',error=? WHERE batch_id=? AND display_order=? AND status='pending'",
                           [.text(reason), .text(asset.batchID), .integer(Int64(asset.displayOrder))])
        }
    }

    func markMissing(_ asset: StoredAsset) throws {
        try db.transaction {
            try db.execute("UPDATE assets SET state='missing',accounted=0 WHERE id=? AND state='ready'", [.text(asset.id)])
            guard db.changes() == 1 else { return }
            try db.execute("UPDATE settings SET total_bytes=MAX(0,total_bytes-?) WHERE id=1", [.integer(asset.byteCount)])
            try db.execute("UPDATE frames SET status='failed',error='image file missing',asset_id=NULL WHERE asset_id=?", [.text(asset.id)])
            try db.execute("""
                UPDATE batches SET success_count=MAX(0,success_count-1),
                  status=CASE WHEN success_count<=1 THEN 'failed' ELSE 'partial' END
                WHERE id=? AND success_count>0
                """, [.text(asset.batchID)])
        }
    }

    func finishInterruptedBatches() throws {
        while true {
            let ids = try db.query("SELECT id FROM batches WHERE status='capturing' LIMIT 100", map: { Self.text($0, 0) })
            if ids.isEmpty { break }
            for id in ids {
                try db.transaction {
                    try db.execute("UPDATE frames SET status='interrupted' WHERE batch_id=? AND status='pending'", [.text(id)])
                    let successes = try db.scalarInt("SELECT COUNT(*) FROM frames WHERE batch_id=? AND status='success'", [.text(id)])
                    try db.execute("UPDATE batches SET status='interrupted',ended_at=?,success_count=? WHERE id=?",
                                   [.real(Date().timeIntervalSince1970), .integer(successes), .text(id)])
                }
            }
        }
    }

    func expiredBatchIDs(cutoff: Date, limit: Int) throws -> [String] {
        try db.query("SELECT id FROM batches WHERE status NOT IN ('capturing','deleting') AND started_at<? ORDER BY started_at,id LIMIT ?",
                     [.real(cutoff.timeIntervalSince1970), .integer(Int64(limit))]) { Self.text($0, 0) }
    }

    func oldestBatchIDs(limit: Int) throws -> [String] {
        try db.query("SELECT id FROM batches WHERE status NOT IN ('capturing','deleting') ORDER BY started_at,id LIMIT ?",
                     [.integer(Int64(limit))]) { Self.text($0, 0) }
    }

    func markDeleting(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.execute("UPDATE batches SET status='deleting' WHERE id=? AND status!='capturing'", [.text(id)])
                if db.changes() == 1 { try db.execute("UPDATE assets SET state='deleting' WHERE batch_id=?", [.text(id)]) }
            }
        }
    }

    func nextDeletingBatch() throws -> String? {
        try db.query("SELECT id FROM batches WHERE status='deleting' ORDER BY started_at,id LIMIT 1", map: { Self.text($0, 0) }).first
    }

    func finalizeDelete(batchID: String) throws {
        try db.transaction {
            let bytes = try db.scalarInt("SELECT COALESCE(SUM(byte_count),0) FROM assets WHERE batch_id=? AND accounted=1", [.text(batchID)])
            try db.execute("UPDATE settings SET total_bytes=MAX(0,total_bytes-?) WHERE id=1", [.integer(bytes)])
            try db.execute("DELETE FROM batches WHERE id=? AND status='deleting'", [.text(batchID)])
        }
    }

    func advanceEpochAndMarkAllDeleting() throws -> Int64 {
        try db.transaction {
            try db.execute("UPDATE settings SET epoch=epoch+1 WHERE id=1")
            try db.execute("UPDATE batches SET status='deleting'")
            try db.execute("UPDATE assets SET state='deleting'")
            return try currentEpoch()
        }
    }

    func history(limit: Int, before: HistoryCursor? = nil) throws -> [StoredBatch] {
        let sql = "SELECT id,started_at,expected_count,success_count,status FROM batches WHERE status!='deleting'" +
            (before == nil ? "" : " AND (started_at<? OR (started_at=? AND id<?))") + " ORDER BY started_at DESC,id DESC LIMIT ?"
        let values: [SQLValue] = (before.map { [.real($0.startedAt.timeIntervalSince1970),
                                                .real($0.startedAt.timeIntervalSince1970), .text($0.id)] } ?? []) + [.integer(Int64(limit))]
        return try db.query(sql, values) { statement in
            StoredBatch(id: Self.text(statement, 0), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        expectedCount: Int(sqlite3_column_int64(statement, 2)), successCount: Int(sqlite3_column_int64(statement, 3)),
                        status: Self.text(statement, 4))
        }
    }

    func frames(batchID: String) throws -> [StoredFrame] {
        try db.query("SELECT display_order,display_id,status,asset_id,error,layout_x,layout_y,layout_width,layout_height,is_mirrored FROM frames WHERE batch_id=? ORDER BY display_order",
                     [.text(batchID)]) { statement in
            StoredFrame(displayOrder: Int(sqlite3_column_int64(statement, 0)),
                        displayID: UInt32(sqlite3_column_int64(statement, 1)), status: Self.text(statement, 2),
                        assetID: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Self.text(statement, 3),
                        error: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Self.text(statement, 4),
                        layoutX: sqlite3_column_double(statement, 5), layoutY: sqlite3_column_double(statement, 6),
                        layoutWidth: sqlite3_column_double(statement, 7), layoutHeight: sqlite3_column_double(statement, 8),
                        isMirrored: sqlite3_column_int64(statement, 9) != 0)
        }
    }

    func oldestAvailableDate() throws -> Date? {
        try db.query("SELECT MIN(started_at) FROM batches WHERE status NOT IN ('deleting','failed','skipped') AND success_count>0") {
            sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }.first ?? nil
    }

    private static func mapAsset(_ statement: OpaquePointer) -> StoredAsset {
        StoredAsset(id: text(statement, 0), batchID: text(statement, 1), displayOrder: Int(sqlite3_column_int64(statement, 2)),
                    relativePath: text(statement, 3), stagingPath: text(statement, 4), byteCount: sqlite3_column_int64(statement, 5),
                    width: Int(sqlite3_column_int64(statement, 6)), height: Int(sqlite3_column_int64(statement, 7)),
                    state: text(statement, 8), accounted: sqlite3_column_int64(statement, 9) != 0,
                    epoch: sqlite3_column_int64(statement, 10),
                    captureStartedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                    captureEndedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)))
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
