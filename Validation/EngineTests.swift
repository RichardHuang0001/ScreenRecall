import Foundation

private struct GrantedPermission: CapturePermissionChecking {
    func isGranted() -> Bool { true }
}

private struct DeniedPermission: CapturePermissionChecking {
    func isGranted() -> Bool { false }
}

private final class TogglePermission: CapturePermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var granted = true
    func isGranted() -> Bool { lock.lock(); defer { lock.unlock() }; return granted }
    func set(_ value: Bool) { lock.lock(); granted = value; lock.unlock() }
}

private enum FakeError: Error { case captureFailed }

private actor FakeProvider: CaptureProviding {
    enum Mode: Equatable { case normal, failSecond, holdFirst, holdSecond }
    var mode: Mode
    private(set) var captureCalls = 0
    private(set) var excludedBundleIDs: Set<String> = []
    private var heldContinuation: CheckedContinuation<Void, Never>?

    init(mode: Mode) { self.mode = mode }

    func prepareBatch(_ batchID: UUID) -> [DisplayDescriptor] {
        [DisplayDescriptor(id: 1, order: 0, pixelWidth: 100, pixelHeight: 100, pointPixelScale: 1),
         DisplayDescriptor(id: 2, order: 1, pixelWidth: 100, pixelHeight: 100, pointPixelScale: 1)]
    }

    func captureToStaging(display: DisplayDescriptor, batchID: UUID) async throws -> CapturedAsset {
        captureCalls += 1
        if (mode == .holdFirst && captureCalls == 1) || (mode == .holdSecond && captureCalls == 2) {
            await withCheckedContinuation { heldContinuation = $0 }
        }
        if mode == .failSecond && display.id == 2 { throw FakeError.captureFailed }
        return CapturedAsset(displayID: display.id,
                             stagingURL: URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString)"),
                             width: 100, height: 100, byteCount: 123, format: "jpeg",
                             captureStartedAt: Date(), captureEndedAt: Date())
    }

    func release() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func finishBatch(_ batchID: UUID) {}
    func setExcludedBundleIDs(_ identifiers: Set<String>) { excludedBundleIDs = identifiers }
}

private actor FakeSink: CaptureConsuming {
    private(set) var consumed = 0
    private(set) var discarded = 0
    private(set) var summaries: [CaptureBatchSummary] = []
    private(set) var retainedByBatch: [UUID: Int] = [:]
    private(set) var revokedBatch: UUID?
    private var minimumGeneration: UInt64 = 0
    func beginBatch(_ batchID: UUID, startedAt: Date, displays: [DisplayDescriptor], generation: UInt64) {}
    func consume(_ asset: CapturedAsset, batchID: UUID, generation: UInt64) {
        guard generation >= minimumGeneration else { return }
        consumed += 1
        retainedByBatch[batchID, default: 0] += 1
    }
    func recordFailure(display: DisplayDescriptor, batchID: UUID, generation: UInt64, message: String) {}
    func discard(_ asset: CapturedAsset) { discarded += 1 }
    func finish(_ summary: CaptureBatchSummary, generation: UInt64) {
        if generation >= minimumGeneration { summaries.append(summary) }
    }
    func clearHistory(minimumGeneration: UInt64) { summaries.removeAll() }
    func invalidatePreviousGeneration(_ generation: UInt64, capturedSince: Date) {
        minimumGeneration = max(minimumGeneration, generation)
        revokedBatch = retainedByBatch.keys.first
        retainedByBatch.removeAll()
        summaries.removeAll { $0.endedAt >= capturedSince }
    }
}

private actor FailingSink: CaptureConsuming {
    enum Mode: Equatable { case begin, consume }
    let mode: Mode
    init(mode: Mode) { self.mode = mode }
    func beginBatch(_ batchID: UUID, startedAt: Date, displays: [DisplayDescriptor], generation: UInt64) throws {
        if mode == .begin { throw FakeError.captureFailed }
    }
    func consume(_ asset: CapturedAsset, batchID: UUID, generation: UInt64) throws {
        if mode == .consume { throw FakeError.captureFailed }
    }
    func recordFailure(display: DisplayDescriptor, batchID: UUID, generation: UInt64, message: String) {}
    func discard(_ asset: CapturedAsset) {}
    func finish(_ summary: CaptureBatchSummary, generation: UInt64) {}
    func clearHistory(minimumGeneration: UInt64) {}
    func invalidatePreviousGeneration(_ minimumGeneration: UInt64, capturedSince: Date) {}
}

private actor TickCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@main
enum EngineTests {
    static func main() async {
        do {
            try await duplicateTriggerAndPartialFailure()
            try await pauseInvalidatesLateCapture()
            try await privacyUpdateRevokesPartiallyCommittedBatch()
            try await privacyUpdateKeepsNeverEnabledState()
            try await stalledBackendNeverOverlaps()
            try await deniedPermissionDoesNotCapture()
            try await storageFailureStopsBatch()
            try await systemPauseCancelsAndResumesOnlyWhenRequested()
            try await permissionRevocationStopsAndRechecks()
            try await timerStops()
            print("PASS: duplicate trigger, partial failure, generation cancellation, privacy update revocation, backend stall, permission denial and revocation, storage failure stop, system pause and resume, timer stop")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "EngineTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func waitForCapture(_ provider: FakeProvider) async throws {
        for _ in 0..<100 {
            if await provider.captureCalls > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "EngineTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "capture did not start"])
    }

    private static func privacyUpdateRevokesPartiallyCommittedBatch() async throws {
        let provider = FakeProvider(mode: .holdSecond)
        let sink = FakeSink()
        let coordinator = CaptureCoordinator(provider: provider, sink: sink,
                                             scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission())
        await coordinator.start()
        let oldCapture = Task { await coordinator.requestCapture(.manual) }
        for _ in 0..<100 {
            if await provider.captureCalls == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(await provider.captureCalls == 2, "second display did not enter capture")
        try expect(await sink.consumed == 1, "first display was not committed before rule update")
        try await coordinator.updateExcludedBundleIDs(["com.example.Secret"])
        try expect(await provider.excludedBundleIDs == ["com.example.Secret"], "new exclusion was not installed")
        try expect(await sink.revokedBatch != nil, "in-flight batch was not revoked")
        try expect(await sink.retainedByBatch.isEmpty, "old rule image remained after update")
        await coordinator.finishPrivacyUpdates()
        await provider.release()
        await oldCapture.value
        try expect(await sink.retainedByBatch.isEmpty, "late image was retained after rule update")
        await coordinator.requestCapture(.manual)
        try expect(await sink.retainedByBatch.values.reduce(0, +) == 2, "new batch did not capture under updated rules")
        await coordinator.stop()
    }

    private static func privacyUpdateKeepsNeverEnabledState() async throws {
        let coordinator = CaptureCoordinator(provider: FakeProvider(mode: .normal), sink: FakeSink(),
                                             scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission())
        try await coordinator.updateExcludedBundleIDs(["com.example.Secret"])
        await coordinator.finishPrivacyUpdates()
        try expect((await coordinator.snapshot()).state == .idle, "saving exclusions before enabling changed idle state")
    }

    private static func duplicateTriggerAndPartialFailure() async throws {
        let provider = FakeProvider(mode: .holdFirst)
        let sink = FakeSink()
        let coordinator = CaptureCoordinator(provider: provider, sink: sink, scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission())
        await coordinator.start()
        let first = Task { await coordinator.requestCapture(.manual) }
        try await waitForCapture(provider)
        await coordinator.requestCapture(.scheduled)
        try expect((await coordinator.snapshot()).skippedBusy == 1, "overlapping trigger was not skipped")
        try expect(await provider.captureCalls == 1, "second capture began while first was held")
        await provider.release()
        await first.value
        try expect((await coordinator.snapshot()).lastBatch?.status == .complete, "full batch did not complete")
        await coordinator.stop()

        let failing = FakeProvider(mode: .failSecond)
        let partial = CaptureCoordinator(provider: failing, sink: FakeSink(), scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission())
        await partial.start()
        await partial.requestCapture(.manual)
        let batch = await partial.snapshot().lastBatch
        try expect(batch?.status == .partial && batch?.expectedCount == 2, "second-screen failure was not partial")
        try expect(batch?.outcomes.filter(\.succeeded).count == 1, "partial batch success count is wrong")
        await partial.stop()
    }

    private static func pauseInvalidatesLateCapture() async throws {
        let provider = FakeProvider(mode: .holdFirst)
        let sink = FakeSink()
        let coordinator = CaptureCoordinator(provider: provider, sink: sink, scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission())
        await coordinator.start()
        let first = Task { await coordinator.requestCapture(.manual) }
        try await waitForCapture(provider)
        await coordinator.pause()
        await provider.release()
        await first.value
        try expect((await coordinator.snapshot()).lastBatch?.status == .interrupted, "late batch was not interrupted")
        let consumed = await sink.consumed
        let discarded = await sink.discarded
        try expect(consumed == 0 && discarded == 1, "late image was not discarded")
        await coordinator.start()
        await coordinator.requestCapture(.manual)
        try expect((await coordinator.snapshot()).lastBatch?.status == .complete, "resume did not work")
        await coordinator.stop()
    }

    private static func stalledBackendNeverOverlaps() async throws {
        let provider = FakeProvider(mode: .holdFirst)
        let coordinator = CaptureCoordinator(provider: provider, sink: FakeSink(), scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission(), backendTimeoutSeconds: 0.1)
        await coordinator.start()
        let first = Task { await coordinator.requestCapture(.manual) }
        try await waitForCapture(provider)
        try await Task.sleep(nanoseconds: 250_000_000)
        try expect((await coordinator.snapshot()).state == .backendStalled, "watchdog did not stop backend")
        try await coordinator.updateExcludedBundleIDs(["com.example.Secret"])
        await coordinator.finishPrivacyUpdates()
        try expect((await coordinator.snapshot()).state == .backendStalled, "rule update restarted a stalled backend")
        await coordinator.requestCapture(.scheduled)
        try expect(await provider.captureCalls == 1, "stalled call overlapped another call")
        await provider.release()
        await first.value
        try expect((await coordinator.snapshot()).state == .backendStalled, "backend restarted automatically")
        await coordinator.resetStalledBackend()
        try expect((await coordinator.snapshot()).state == .idle, "manual reset failed")
    }

    private static func timerStops() async throws {
        let counter = TickCounter()
        let scheduler = CaptureScheduler(intervalSeconds: 1)
        await scheduler.start { Task { await counter.increment() } }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        await scheduler.stop()
        let before = await counter.value
        try expect(before > 0, "timer never fired")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try expect(await counter.value == before, "timer fired after stop")
    }

    private static func deniedPermissionDoesNotCapture() async throws {
        let provider = FakeProvider(mode: .normal)
        let coordinator = CaptureCoordinator(provider: provider, sink: FakeSink(), scheduler: CaptureScheduler(intervalSeconds: 1), permission: DeniedPermission())
        await coordinator.start()
        try expect((await coordinator.snapshot()).state == .awaitingPermission, "missing permission did not block start")
        await coordinator.requestCapture(.manual)
        try expect(await provider.captureCalls == 0, "capture ran without permission")
        await coordinator.stop()
    }

    private static func storageFailureStopsBatch() async throws {
        for mode in [FailingSink.Mode.begin, .consume] {
            let provider = FakeProvider(mode: .normal)
            let coordinator = CaptureCoordinator(provider: provider, sink: FailingSink(mode: mode),
                                                 scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission())
            await coordinator.start()
            await coordinator.requestCapture(.manual)
            try expect((await coordinator.snapshot()).state == .storageUnavailable, "storage failure did not stop scheduler")
            let count = await provider.captureCalls
            try expect(count == (mode == .begin ? 0 : 1), "storage failure continued to next screen")
            await coordinator.stop()
        }
    }

    private static func systemPauseCancelsAndResumesOnlyWhenRequested() async throws {
        let provider = FakeProvider(mode: .holdFirst)
        let sink = FakeSink()
        let coordinator = CaptureCoordinator(provider: provider, sink: sink, scheduler: CaptureScheduler(intervalSeconds: 3600), permission: GrantedPermission())
        await coordinator.start()
        let first = Task { await coordinator.requestCapture(.manual) }
        try await waitForCapture(provider)
        await coordinator.suspendForSystem("sleep")
        await coordinator.suspendForSystem("thermal")
        await provider.release()
        await first.value
        try expect((await coordinator.snapshot()).state == .pausedBySystem, "system pause was lost")
        try expect(await sink.consumed == 0, "late image was stored during system pause")
        await coordinator.resumeFromSystem("sleep")
        try expect((await coordinator.snapshot()).state == .pausedBySystem, "resumed with another blocking reason")
        await coordinator.resumeFromSystem("thermal")
        try expect((await coordinator.snapshot()).state == .ready, "did not resume after system recovered")
        await coordinator.pause()
        await coordinator.suspendForSystem("session")
        await coordinator.resumeFromSystem("session")
        try expect((await coordinator.snapshot()).state == .pausedByUser, "system event overrode user pause")
        await coordinator.stop()
    }

    private static func permissionRevocationStopsAndRechecks() async throws {
        let permission = TogglePermission()
        let provider = FakeProvider(mode: .normal)
        let coordinator = CaptureCoordinator(provider: provider, sink: FakeSink(), scheduler: CaptureScheduler(intervalSeconds: 3600), permission: permission)
        await coordinator.start()
        permission.set(false)
        await coordinator.recheckPermission()
        try expect((await coordinator.snapshot()).state == .awaitingPermission, "revocation did not stop capture")
        await coordinator.requestCapture(.manual)
        try expect(await provider.captureCalls == 0, "captured after permission revocation")
        permission.set(true)
        await coordinator.recheckPermission()
        try expect((await coordinator.snapshot()).state == .ready, "permission recovery did not recheck")
        await coordinator.stop()
    }
}
