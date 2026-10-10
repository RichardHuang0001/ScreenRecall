import CoreGraphics
import Foundation

struct MacCapturePermission: CapturePermissionChecking {
    func isGranted() -> Bool { CGPreflightScreenCaptureAccess() }
}

private enum CoordinatorError: LocalizedError {
    case noDisplays
    var errorDescription: String? { "没有可采集的显示器" }
}

actor CaptureCoordinator {
    private let provider: any CaptureProviding
    private let sink: any CaptureConsuming
    private let scheduler: CaptureScheduler
    private let permission: any CapturePermissionChecking
    private let onUpdate: @Sendable (CaptureSnapshot) -> Void
    private let backendTimeoutNanoseconds: UInt64

    private var state: CaptureState = .idle
    private var batchInFlight: UUID?
    private var activeBackendCall: UUID?
    private var captureGeneration: UInt64 = 0
    private var completedBatches = 0
    private var skippedBusy = 0
    private var skippedUnavailable = 0
    private var lastBatch: CaptureBatchSummary?
    private var wantsCapture = false
    private var systemPauseReasons: Set<String> = []
    private var privacyUpdateInProgress = false
    private var privacyWasIdle = false

    init(provider: any CaptureProviding, sink: any CaptureConsuming, scheduler: CaptureScheduler,
         permission: any CapturePermissionChecking, backendTimeoutSeconds: Double = 10,
         onUpdate: @escaping @Sendable (CaptureSnapshot) -> Void = { _ in }) {
        self.provider = provider
        self.sink = sink
        self.scheduler = scheduler
        self.permission = permission
        self.onUpdate = onUpdate
        backendTimeoutNanoseconds = UInt64(max(0.01, backendTimeoutSeconds) * 1_000_000_000)
    }

    func snapshot() -> CaptureSnapshot {
        CaptureSnapshot(state: state, batchInFlight: batchInFlight != nil, generation: captureGeneration,
                        completedBatches: completedBatches, skippedBusy: skippedBusy,
                        skippedUnavailable: skippedUnavailable, lastBatch: lastBatch)
    }

    func start() async {
        wantsCapture = true
        guard !privacyUpdateInProgress else { return }
        guard state != .backendStalled else { return }
        guard systemPauseReasons.isEmpty else {
            state = .pausedBySystem
            publish()
            return
        }
        guard permission.isGranted() else {
            state = .awaitingPermission
            await scheduler.stop()
            publish()
            return
        }
        state = batchInFlight == nil ? .ready : .capturing
        publish()
        await scheduler.start { [weak self] in
            Task { await self?.requestCapture(.scheduled) }
        }
        if state != .ready && state != .capturing { await scheduler.stop() }
    }

    func pause() async {
        wantsCapture = false
        captureGeneration &+= 1
        state = .pausedByUser
        publish()
        await scheduler.stop()
    }

    func stop() async {
        wantsCapture = false
        captureGeneration &+= 1
        state = .idle
        publish()
        await scheduler.stop()
    }

    func resetStalledBackend() async {
        guard state == .backendStalled, batchInFlight == nil else { return }
        state = .idle
        publish()
    }

    func clearHistory() async throws {
        wantsCapture = false
        captureGeneration &+= 1
        let generation = captureGeneration
        state = .pausedByUser
        publish()
        await scheduler.stop()
        try await sink.clearHistory(minimumGeneration: generation)
    }

    /// A rule change revokes the current batch, including frames already committed by it.
    /// The sink's generation gate is installed before the provider receives new rules.
    func updateExcludedBundleIDs(_ identifiers: Set<String>, changedAt: Date = Date()) async throws {
        if !privacyUpdateInProgress { privacyWasIdle = state == .idle }
        privacyUpdateInProgress = true
        let preserveErrorState = state == .backendStalled || state == .storageUnavailable
        captureGeneration &+= 1
        let generation = captureGeneration
        if !preserveErrorState { state = .pausedBySystem }
        publish()
        await scheduler.stop()
        try await sink.invalidatePreviousGeneration(generation, capturedSince: changedAt)
        await provider.setExcludedBundleIDs(identifiers)
    }

    /// Called after all queued setting changes have applied, so no intermediate rule set runs.
    func finishPrivacyUpdates() async {
        privacyUpdateInProgress = false
        guard state != .backendStalled, state != .storageUnavailable else { return }
        if wantsCapture { await start() }
        else if systemPauseReasons.isEmpty {
            state = privacyWasIdle ? .idle : .pausedByUser
            publish()
        }
    }

    func suspendForSystem(_ reason: String) async {
        guard systemPauseReasons.insert(reason).inserted else { return }
        captureGeneration &+= 1
        if wantsCapture { state = .pausedBySystem }
        publish()
        await scheduler.stop()
    }

    func resumeFromSystem(_ reason: String) async {
        systemPauseReasons.remove(reason)
        guard systemPauseReasons.isEmpty, wantsCapture else { return }
        await start()
    }

    func recheckPermission() async {
        guard wantsCapture else { return }
        if !permission.isGranted() {
            captureGeneration &+= 1
            state = .awaitingPermission
            publish()
            await scheduler.stop()
        } else if state == .awaitingPermission {
            await start()
        }
    }

    func requestCapture(_ trigger: CaptureTrigger) async {
        guard batchInFlight == nil else {
            skippedBusy += 1
            publish()
            return
        }
        guard state == .ready else {
            skippedUnavailable += 1
            publish()
            return
        }
        guard permission.isGranted() else {
            state = .awaitingPermission
            skippedUnavailable += 1
            await scheduler.stop()
            publish()
            return
        }

        let batchID = UUID()
        let generation = captureGeneration
        let startedAt = Date()
        batchInFlight = batchID
        state = .capturing
        publish()
        var expectedCount = 0
        var outcomes: [FrameOutcome] = []
        var errorSummary: String?
        var interrupted = false
        var storageFailed = false
        do {
            let prepareCallID = UUID()
            activeBackendCall = prepareCallID
            let prepareWatchdog = makeWatchdog(batchID: batchID, generation: generation, callID: prepareCallID)
            let displays: [DisplayDescriptor]
            do {
                displays = try await provider.prepareBatch(batchID)
                activeBackendCall = nil
                prepareWatchdog.cancel()
            } catch {
                activeBackendCall = nil
                prepareWatchdog.cancel()
                throw error
            }
            expectedCount = displays.count
            if displays.isEmpty { throw CoordinatorError.noDisplays }
            do {
                try await sink.beginBatch(batchID, startedAt: startedAt, displays: displays, generation: generation)
            } catch {
                storageFailed = true
                throw error
            }
            for display in displays {
                if generation != captureGeneration || state == .backendStalled {
                    interrupted = true
                    break
                }
                do {
                    let captureCallID = UUID()
                    activeBackendCall = captureCallID
                    let captureWatchdog = makeWatchdog(batchID: batchID, generation: generation, callID: captureCallID)
                    let asset: CapturedAsset
                    do {
                        asset = try await provider.captureToStaging(display: display, batchID: batchID)
                        activeBackendCall = nil
                        captureWatchdog.cancel()
                    } catch {
                        activeBackendCall = nil
                        captureWatchdog.cancel()
                        throw error
                    }
                    if generation != captureGeneration || state == .backendStalled {
                        await sink.discard(asset)
                        interrupted = true
                        break
                    }
                    do {
                        try await sink.consume(asset, batchID: batchID, generation: generation)
                        outcomes.append(FrameOutcome(displayID: display.id, succeeded: true, error: nil))
                    } catch {
                        await sink.discard(asset)
                        if generation != captureGeneration { interrupted = true; break }
                        let message = error.localizedDescription
                        outcomes.append(FrameOutcome(displayID: display.id, succeeded: false, error: message))
                        errorSummary = message
                        storageFailed = true
                        try? await sink.recordFailure(display: display, batchID: batchID, generation: generation, message: message)
                        interrupted = true
                        break
                    }
                } catch {
                    if generation != captureGeneration || state == .backendStalled { interrupted = true; break }
                    let message = error.localizedDescription
                    outcomes.append(FrameOutcome(displayID: display.id, succeeded: false, error: message))
                    do { try await sink.recordFailure(display: display, batchID: batchID, generation: generation, message: message) }
                    catch { errorSummary = error.localizedDescription; storageFailed = true; interrupted = true; break }
                }
            }
        } catch {
            errorSummary = error.localizedDescription
        }
        await provider.finishBatch(batchID)
        if storageFailed {
            state = .storageUnavailable
            await scheduler.stop()
        }
        if generation != captureGeneration || state == .backendStalled { interrupted = true }
        let successes = outcomes.filter(\.succeeded).count
        let status: CaptureBatchStatus = interrupted ? .interrupted :
            successes == expectedCount && expectedCount > 0 ? .complete :
            successes > 0 ? .partial : .failed
        let summary = CaptureBatchSummary(id: batchID, startedAt: startedAt, endedAt: Date(),
                                          status: status, expectedCount: expectedCount,
                                          outcomes: outcomes, errorSummary: errorSummary)
        do {
            try await sink.finish(summary, generation: generation)
        } catch {
            state = .storageUnavailable
            await scheduler.stop()
        }
        completedBatches += 1
        lastBatch = summary
        batchInFlight = nil
        activeBackendCall = nil
        if state == .capturing { state = .ready }
        publish()
    }

    private func markBackendStalled(batchID: UUID, generation: UInt64, callID: UUID) async {
        guard batchInFlight == batchID, activeBackendCall == callID, captureGeneration == generation else { return }
        captureGeneration &+= 1
        state = .backendStalled
        publish()
        await scheduler.stop()
    }

    private func makeWatchdog(batchID: UUID, generation: UInt64, callID: UUID) -> Task<Void, Never> {
        let timeout = backendTimeoutNanoseconds
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            await self?.markBackendStalled(batchID: batchID, generation: generation, callID: callID)
        }
    }

    private func publish() { onUpdate(snapshot()) }
}
