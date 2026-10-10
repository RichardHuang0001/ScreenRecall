import Foundation

enum CaptureState: String, Sendable, Codable {
    case idle, awaitingPermission, ready, capturing, pausedByUser
    case pausedBySystem, storageUnavailable, backendStalled, error
}

enum CaptureTrigger: Sendable { case scheduled, manual }
enum CaptureBatchStatus: String, Sendable, Codable { case complete, partial, failed, skipped, interrupted }

struct DisplayDescriptor: Sendable {
    let id: UInt32
    let order: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let pointPixelScale: Double
    let layoutX: Double
    let layoutY: Double
    let layoutWidth: Double
    let layoutHeight: Double
    let isMirrored: Bool

    init(id: UInt32, order: Int, pixelWidth: Int, pixelHeight: Int, pointPixelScale: Double,
         layoutX: Double = 0, layoutY: Double = 0, layoutWidth: Double = 0, layoutHeight: Double = 0,
         isMirrored: Bool = false) {
        self.id = id
        self.order = order
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointPixelScale = pointPixelScale
        self.layoutX = layoutX
        self.layoutY = layoutY
        self.layoutWidth = layoutWidth
        self.layoutHeight = layoutHeight
        self.isMirrored = isMirrored
    }
}

struct CapturedAsset: Sendable {
    let displayID: UInt32
    let stagingURL: URL
    let width: Int
    let height: Int
    let byteCount: Int64
    let format: String
    let captureStartedAt: Date
    let captureEndedAt: Date
}

struct FrameOutcome: Sendable {
    let displayID: UInt32
    let succeeded: Bool
    let error: String?
}

struct CaptureBatchSummary: Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let status: CaptureBatchStatus
    let expectedCount: Int
    let outcomes: [FrameOutcome]
    let errorSummary: String?
}

struct CaptureSnapshot: Sendable {
    let state: CaptureState
    let batchInFlight: Bool
    let generation: UInt64
    let completedBatches: Int
    let skippedBusy: Int
    let skippedUnavailable: Int
    let lastBatch: CaptureBatchSummary?
}

protocol CaptureProviding: Sendable {
    func prepareBatch(_ batchID: UUID) async throws -> [DisplayDescriptor]
    func captureToStaging(display: DisplayDescriptor, batchID: UUID) async throws -> CapturedAsset
    func finishBatch(_ batchID: UUID) async
}

protocol CaptureConsuming: Sendable {
    func beginBatch(_ batchID: UUID, startedAt: Date, displays: [DisplayDescriptor], generation: UInt64) async throws
    func consume(_ asset: CapturedAsset, batchID: UUID, generation: UInt64) async throws
    func recordFailure(display: DisplayDescriptor, batchID: UUID, generation: UInt64, message: String) async throws
    func discard(_ asset: CapturedAsset) async
    func finish(_ summary: CaptureBatchSummary, generation: UInt64) async throws
    func clearHistory(minimumGeneration: UInt64) async throws
}

protocol CapturePermissionChecking: Sendable {
    func isGranted() -> Bool
}
