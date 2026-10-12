import AppKit
import CoreGraphics
import ServiceManagement

/// Modern layered displays with refined depth, clean typography, and responsive state indicators.
/// Follows macOS HIG template icon conventions; automatically tints for light/dark menu bars.
@MainActor
private enum StatusBarIcon {
    private static var cache: [CaptureState: NSImage] = [:]

    static func image(for state: CaptureState) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // 1. Secondary/Rear display frame (layered in upper right, scaled to fill)
            let rear = NSBezierPath()
            rear.lineWidth = 1.3
            rear.lineCapStyle = .round
            rear.lineJoinStyle = .round
            rear.move(to: NSPoint(x: 5.2, y: 16.6))
            rear.line(to: NSPoint(x: 15.2, y: 16.6))
            rear.curve(to: NSPoint(x: 17.0, y: 14.8),
                       controlPoint1: NSPoint(x: 16.2, y: 16.6),
                       controlPoint2: NSPoint(x: 17.0, y: 15.8))
            rear.line(to: NSPoint(x: 17.0, y: 5.8))
            rear.stroke()

            // 2. Primary/Front display frame (anchored in lower left, scaled to 13.4 x 11.2)
            let front = NSBezierPath(roundedRect: NSRect(x: 1.0, y: 1.6, width: 13.4, height: 11.2),
                                     xRadius: 2.0, yRadius: 2.0)
            front.lineWidth = 1.4
            front.stroke()

            // 3. Center indicator & state glyphs
            switch state {
            case .pausedByUser, .pausedBySystem:
                // Clean bold pause bars centered in front display
                let pause = NSBezierPath()
                pause.lineWidth = 1.35
                pause.lineCapStyle = .round
                pause.move(to: NSPoint(x: 6.6, y: 5.3))
                pause.line(to: NSPoint(x: 6.6, y: 9.1))
                pause.move(to: NSPoint(x: 8.8, y: 5.3))
                pause.line(to: NSPoint(x: 8.8, y: 9.1))
                pause.stroke()

            case .awaitingPermission, .storageUnavailable, .backendStalled, .error:
                // Sharp exclamation mark for alert/error states
                let alert = NSBezierPath()
                alert.lineWidth = 1.4
                alert.lineCapStyle = .round
                alert.move(to: NSPoint(x: 7.7, y: 6.7))
                alert.line(to: NSPoint(x: 7.7, y: 9.3))
                alert.stroke()
                NSBezierPath(ovalIn: NSRect(x: 6.85, y: 5.0, width: 1.7, height: 1.7)).fill()

            case .capturing:
                // Clock ring + active capture pulse dot, with secondary screen capture flare
                let dial = NSBezierPath(ovalIn: NSRect(x: 5.1, y: 4.6, width: 5.2, height: 5.2))
                dial.lineWidth = 1.15
                dial.stroke()
                NSBezierPath(ovalIn: NSRect(x: 6.5, y: 6.0, width: 2.4, height: 2.4)).fill()
                // Dual-screen sync indicator on rear screen corner
                NSBezierPath(ovalIn: NSRect(x: 15.3, y: 14.9, width: 1.7, height: 1.7)).fill()

            default:
                // Ready / Idle state: refined clock dial with elegant hands
                let dial = NSBezierPath(ovalIn: NSRect(x: 5.1, y: 4.6, width: 5.2, height: 5.2))
                dial.lineWidth = 1.15
                dial.stroke()

                let hands = NSBezierPath()
                hands.lineWidth = 1.1
                hands.lineCapStyle = .round
                hands.move(to: NSPoint(x: 7.7, y: 7.2))
                hands.line(to: NSPoint(x: 7.7, y: 8.6))
                hands.move(to: NSPoint(x: 7.7, y: 7.2))
                hands.line(to: NSPoint(x: 8.7, y: 7.8))
                hands.stroke()
            }

            return true
        }
        image.isTemplate = true
        cache[state] = image
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var coordinator: CaptureCoordinator?
    private var persistentSink: PersistentCaptureSink?
    private var captureProvider: MacScreenCaptureProvider?
    private var systemEvents: SystemEventMonitor?
    private var historyController: HistoryWindowController?
    private var phase4SmokeRoot: URL?
    private var preferences = AppPreferences()
    private var maintenanceRunning = false
    private var maintenanceAllowed = true
    private var maintenanceTask: Task<Void, Never>?
    private var pendingPrivacyExclusions: Set<String>?
    private var pendingPrivacyChangedAt: Date?
    private var applyingPrivacyRules = false
    private var lastMaintainedBatchCount = -1
    private var currentState: CaptureState = .idle
    private var currentStateDescription = "未启动"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--headless-probe") {
            Task {
                guard CGPreflightScreenCaptureAccess() else {
                    fputs("Screen recording permission is not granted to this app.\n", stderr)
                    NSApplication.shared.terminate(nil)
                    return
                }
                do {
                    let result = try await PlatformProbe.run()
                    let output = try JSONEncoder.pretty.encode(result)
                    FileHandle.standardOutput.write(output)
                    FileHandle.standardOutput.write(Data([0x0a]))
                } catch {
                    fputs("Probe failed: \(error)\n", stderr)
                }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--engine-smoke") {
            runEngineSmoke()
            return
        }
        if CommandLine.arguments.contains("--storage-smoke") {
            runStorageSmoke()
            return
        }
        if CommandLine.arguments.contains("--phase3-soak") {
            runPhase3Soak()
            return
        }
        if CommandLine.arguments.contains("--phase4-smoke") {
            runPhase4Smoke(openWindow: false)
            return
        }
        if CommandLine.arguments.contains("--phase4-window-smoke") {
            runPhase4Smoke(openWindow: true)
            return
        }
        if CommandLine.arguments.contains("--ui-snapshot") {
            runPhase4Smoke(openWindow: true, takeSnapshot: true)
            return
        }
        if CommandLine.arguments.contains("--phase5-benchmark") {
            guard CGPreflightScreenCaptureAccess() else {
                fputs("Screen recording permission is not granted to this app.\n", stderr)
                NSApplication.shared.terminate(nil)
                return
            }
            Task {
                do {
                    let report = try await PerformanceBenchmark.run(arguments: CommandLine.arguments)
                    FileHandle.standardOutput.write(try JSONEncoder.pretty.encode(report))
                    FileHandle.standardOutput.write(Data([0x0a]))
                } catch { fputs("Performance benchmark failed: \(error)\n", stderr) }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        updateStatusIcon(.idle, description: "未启动")
        item.button?.target = self
        item.button?.action = #selector(openHistory)
        do {
            let paths = try StoragePaths()
            let sink = try PersistentCaptureSink(paths: paths,
                policy: .configured(hours: preferences.retentionHours, maximumGiB: preferences.maximumGiB))
            let provider = MacScreenCaptureProvider(root: paths.staging)
            persistentSink = sink
            captureProvider = provider
            let scheduler = CaptureScheduler(intervalSeconds: preferences.intervalSeconds)
            let coordinator = CaptureCoordinator(provider: provider, sink: sink,
                                                 scheduler: scheduler, permission: MacCapturePermission()) { [weak self] snapshot in
                Task { @MainActor in self?.updateStatus(snapshot) }
            }
            self.coordinator = coordinator
            systemEvents = SystemEventMonitor(coordinator: coordinator) { [weak self] allowed in
                self?.maintenanceAllowed = allowed
                if !allowed { self?.maintenanceTask?.cancel() }
            }
            Task {
                do {
                    try await sink.recover()
                    await provider.setExcludedBundleIDs(preferences.excludedBundleIDs)
                    if preferences.captureEnabled { await coordinator.start() }
                    else { updateStatus(await coordinator.snapshot()) }
                    runMaintenanceIfNeeded()
                } catch { showResult("历史数据初始化失败：\(error.localizedDescription)") }
            }
        } catch {
            currentState = .storageUnavailable
            currentStateDescription = "存储不可用"
            updateStatusIcon(.storageUnavailable, description: "存储不可用")
            showResult("无法打开历史数据目录：\(error.localizedDescription)")
        }
    }

    private func makeCoordinator(sink: EphemeralCaptureSink) -> CaptureCoordinator {
        CaptureCoordinator(provider: MacScreenCaptureProvider(), sink: sink,
                           scheduler: CaptureScheduler(), permission: MacCapturePermission()) { [weak self] snapshot in
            Task { @MainActor in self?.updateStatus(snapshot) }
        }
    }

    private func updateStatus(_ snapshot: CaptureSnapshot) {
        let stateDescription: String
        switch snapshot.state {
        case .idle: stateDescription = "未启动"
        case .awaitingPermission: stateDescription = "需要屏幕录制权限"
        case .ready: stateDescription = "运行中"
        case .capturing: stateDescription = "正在截图"
        case .pausedByUser: stateDescription = "已暂停"
        case .pausedBySystem: stateDescription = "系统暂停"
        case .storageUnavailable: stateDescription = "存储不可用"
        case .backendStalled: stateDescription = "截图后端无响应"
        case .error: stateDescription = "出错"
        }
        updateStatusIcon(snapshot.state, description: stateDescription)
        currentState = snapshot.state
        currentStateDescription = stateDescription
        historyController?.controls.update(state: snapshot.state, description: stateDescription,
            lastBatch: snapshot.lastBatch.map { "最近批次 \(batchStatusText($0.status)) · \($0.outcomes.filter(\.succeeded).count)/\($0.expectedCount) 屏" },
            intervalSeconds: preferences.intervalSeconds)
        if snapshot.completedBatches != lastMaintainedBatchCount && snapshot.state != .capturing {
            lastMaintainedBatchCount = snapshot.completedBatches
            runMaintenanceIfNeeded()
            if historyController != nil { Task { await historyController?.model.refreshLatest() } }
        }
    }

    private func updateStatusIcon(_ state: CaptureState, description: String) {
        guard let button = statusItem?.button else { return }
        let label = "ScreenRecall：\(description)"
        button.image = StatusBarIcon.image(for: state)
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func batchStatusText(_ status: CaptureBatchStatus) -> String {
        switch status {
        case .complete: "完整"
        case .partial: "部分成功"
        case .failed: "失败"
        case .skipped: "已跳过"
        case .interrupted: "已中断"
        }
    }

    @objc private func openHistory() {
        guard let sink = persistentSink else { showResult("历史数据不可用"); return }
        if historyController == nil {
            let settings = HistorySettings(excludedBundleIDs: preferences.excludedBundleIDs,
                retentionHours: preferences.retentionHours, maximumGiB: preferences.maximumGiB,
                intervalSeconds: preferences.intervalSeconds,
                loginAtStart: SMAppService.mainApp.status == .enabled)
            let actions = HistoryActions(
                start: { [weak self] in self?.startCapture() },
                pause: { [weak self] in self?.pauseCapture() },
                resume: { [weak self] in self?.resumeCapture() },
                captureNow: { [weak self] in self?.manualCapture() },
                saveSettings: { [weak self] ids, hours, gib, interval in self?.saveSettings(ids: ids, hours: hours, gib: gib, interval: interval) },
                setLoginAtStart: { [weak self] enabled in self?.setLoginAtStart(enabled) ?? false },
                clearHistory: { [weak self] in self?.clearHistory() },
                openDataFolder: { [weak self] in self?.openDataFolder() },
                runProbe: { [weak self] in self?.runProbe() },
                quit: { [weak self] in self?.quitApp() })
            historyController = HistoryWindowController(sink: sink, settings: settings, actions: actions) { [weak self] in
                self?.historyController = nil
            }
            historyController?.controls.update(state: currentState, description: currentStateDescription,
                lastBatch: nil, intervalSeconds: preferences.intervalSeconds)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        historyController?.window?.deminiaturize(nil)
        historyController?.showWindow(nil)
        historyController?.window?.makeKeyAndOrderFront(nil)
    }

    private func runPhase4Smoke(openWindow: Bool, takeSnapshot: Bool = false) {
        Task {
            do {
                let (paths, sink) = try await HistorySmoke.makeDataset()
                phase4SmokeRoot = paths.root
                if openWindow {
                    NSApplication.shared.setActivationPolicy(.regular)
                    historyController = HistoryWindowController(sink: sink,
                        settings: HistorySettings(excludedBundleIDs: [], retentionHours: 24, maximumGiB: 2,
                                                  loginAtStart: false), actions: .preview) { [weak self] in
                        self?.historyController = nil
                        NSApplication.shared.terminate(nil)
                    }
                    historyController?.showWindow(nil)
                    historyController?.window?.makeKeyAndOrderFront(nil)
                    if takeSnapshot {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenrecall-063-history-preview.png")
                        try historyController?.saveSnapshot(to: url)
                        print("UI snapshot: \(url.path)")
                        let settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("screenrecall-063-settings-preview.png")
                        try historyController?.saveSettingsSnapshot(to: settingsURL)
                        print("Settings snapshot: \(settingsURL.path)")
                        NSApplication.shared.terminate(nil)
                    }
                } else {
                    let report = try await HistorySmoke.verify(paths: paths, sink: sink)
                    FileHandle.standardOutput.write(try JSONEncoder.pretty.encode(report))
                    FileHandle.standardOutput.write(Data([0x0a]))
                    try? FileManager.default.removeItem(at: paths.root)
                    phase4SmokeRoot = nil
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                fputs("Phase 4 smoke failed: \(error)\n", stderr)
                if let phase4SmokeRoot { try? FileManager.default.removeItem(at: phase4SmokeRoot) }
                if openWindow { NSApplication.shared.terminate(nil) }
                else { exit(1) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let phase4SmokeRoot { try? FileManager.default.removeItem(at: phase4SmokeRoot) }
    }

    private func runMaintenanceIfNeeded() {
        guard maintenanceAllowed, !maintenanceRunning, let sink = persistentSink else { return }
        maintenanceRunning = true
        maintenanceTask = Task(priority: .utility) {
            do {
                try await sink.enforceRetentionCooperatively(now: Date())
                if !Task.isCancelled { _ = try await sink.auditNextReadyAssets(limit: 2) }
            }
            catch { /* 下次空闲批次重试；采集错误单独在状态栏提示。 */ }
            maintenanceRunning = false
            maintenanceTask = nil
        }
    }

    @objc private func startCapture() {
        guard let coordinator else { showResult("存储不可用，无法启用屏幕历史。"); return }
        preferences.captureEnabled = true
        Task { await coordinator.start() }
    }

    @objc private func pauseCapture() {
        preferences.captureEnabled = false
        Task { await coordinator?.pause() }
    }
    @objc private func resumeCapture() {
        preferences.captureEnabled = true
        Task { await coordinator?.start() }
    }
    @objc private func manualCapture() { Task { await coordinator?.requestCapture(.manual) } }

    private func saveSettings(ids: Set<String>, hours: Int, gib: Int, interval: Int) {
        let changedAt = Date()
        preferences.excludedBundleIDs = ids
        pendingPrivacyExclusions = ids
        pendingPrivacyChangedAt = changedAt
        if !applyingPrivacyRules {
            applyingPrivacyRules = true
            Task {
                var applied = false
                while let nextIDs = pendingPrivacyExclusions {
                    let effectiveFrom = pendingPrivacyChangedAt ?? Date()
                    pendingPrivacyExclusions = nil
                    pendingPrivacyChangedAt = nil
                    do {
                        try await coordinator?.updateExcludedBundleIDs(nextIDs, changedAt: effectiveFrom)
                        applied = true
                    }
                    catch {
                        applied = false
                        showResult("隐私排除规则未能完成更新，采集已暂停：\(error.localizedDescription)")
                    }
                }
                if applied { await coordinator?.finishPrivacyUpdates() }
                applyingPrivacyRules = false
            }
        }
        preferences.retentionHours = hours
        preferences.maximumGiB = gib
        preferences.intervalSeconds = interval
        Task {
            await coordinator?.updateCaptureInterval(interval)
            await persistentSink?.updateRetentionPolicy(.configured(hours: hours, maximumGiB: gib))
            try? await persistentSink?.enforceRetentionCooperatively(now: Date())
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "永久清空全部屏幕历史？"
        alert.informativeText = "此操作会删除本机保存的截图和历史记录，并暂停采集。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        preferences.captureEnabled = false
        Task {
            do {
                guard let coordinator else { throw StorageError.cleanupIncomplete }
                try await coordinator.clearHistory()
                await historyController?.model.reload()
                showResult("历史已清空，采集已暂停。")
            }
            catch { showResult("清空失败：\(error.localizedDescription)") }
        }
    }

    @objc private func openDataFolder() {
        if let url = persistentSink?.paths.root { NSWorkspace.shared.open(url) }
    }

    private func setLoginAtStart(_ enabled: Bool) -> Bool {
        do {
            if enabled && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !enabled && SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch { showResult("登录项设置失败：\(error.localizedDescription)") }
        return SMAppService.mainApp.status == .enabled
    }

    private func runEngineSmoke() {
        guard CGPreflightScreenCaptureAccess() else {
            fputs("Screen recording permission is not granted to this app.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        let sink = EphemeralCaptureSink()
        let coordinator = makeCoordinator(sink: sink)
        self.coordinator = coordinator
        Task {
            await coordinator.start()
            await coordinator.requestCapture(.manual)
            try? await Task.sleep(nanoseconds: 66_000_000_000)
            await coordinator.stop()
            let snapshot = await coordinator.snapshot()
            let batches = await sink.recentSummaries()
            let report = EngineSmokeReport(batchCount: batches.count,
                                           startedAt: batches.map { ISO8601DateFormatter().string(from: $0.startedAt) },
                                           statuses: batches.map { $0.status.rawValue },
                                           expectedCounts: batches.map(\.expectedCount),
                                           succeededCounts: batches.map { $0.outcomes.filter(\.succeeded).count },
                                           skippedBusy: snapshot.skippedBusy,
                                           skippedUnavailable: snapshot.skippedUnavailable)
            if let output = try? JSONEncoder.pretty.encode(report) {
                FileHandle.standardOutput.write(output)
                FileHandle.standardOutput.write(Data([0x0a]))
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private func runStorageSmoke() {
        guard CGPreflightScreenCaptureAccess() else {
            fputs("Screen recording permission is not granted to this app.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        Task {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecall-StorageSmoke-\(UUID().uuidString)", isDirectory: true)
                let paths = try StoragePaths(root: root)
                defer { try? FileManager.default.removeItem(at: root) }
                let sink = try PersistentCaptureSink(paths: paths)
                let coordinator = CaptureCoordinator(provider: MacScreenCaptureProvider(root: paths.staging), sink: sink,
                                                     scheduler: CaptureScheduler(), permission: MacCapturePermission())
                await coordinator.start()
                await coordinator.requestCapture(.manual)
                await coordinator.stop()
                let before = try await sink.status()
                let history = try await sink.history()
                let ready = try HistoryRepository(url: paths.database).assets(state: "ready")
                let filesExist = ready.allSatisfy { FileManager.default.fileExists(atPath: paths.root.appendingPathComponent($0.relativePath).path) }
                try await coordinator.clearHistory()
                let after = try await sink.status()
                let report = StorageSmokeReport(batchCountBeforeClear: before.batchCount,
                                                batchStatuses: history.map(\.status),
                                                readyAssetsBeforeClear: ready.count,
                                                allFilesExisted: filesExist,
                                                bytesBeforeClear: before.totalBytes,
                                                batchCountAfterClear: after.batchCount,
                                                bytesAfterClear: after.totalBytes)
                let output = try JSONEncoder.pretty.encode(report)
                FileHandle.standardOutput.write(output)
                FileHandle.standardOutput.write(Data([0x0a]))
            } catch {
                fputs("Storage smoke failed: \(error)\n", stderr)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private func runPhase3Soak() {
        guard CGPreflightScreenCaptureAccess() else {
            fputs("Screen recording permission is not granted to this app.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        Task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecall-Phase3Soak-\(UUID().uuidString)", isDirectory: true)
            do {
                let paths = try StoragePaths(root: root)
                let sink = try PersistentCaptureSink(paths: paths)
                let coordinator = CaptureCoordinator(provider: MacScreenCaptureProvider(root: paths.staging), sink: sink,
                                                     scheduler: CaptureScheduler(), permission: MacCapturePermission())
                let wallStart = Date()
                await coordinator.start()
                await coordinator.requestCapture(.manual)
                try await Task.sleep(nanoseconds: 66_000_000_000)
                await coordinator.stop()
                let batches = try await sink.history(limit: 10)
                let status = try await sink.status()
                let report = Phase3SoakReport(elapsedSeconds: Date().timeIntervalSince(wallStart),
                                              batchCount: status.batchCount,
                                              statuses: batches.map(\.status),
                                              totalBytes: status.totalBytes,
                                              readyAssets: try HistoryRepository(url: paths.database).assets(state: "ready").count)
                FileHandle.standardOutput.write(try JSONEncoder.pretty.encode(report))
                FileHandle.standardOutput.write(Data([0x0a]))
                try await coordinator.clearHistory()
            } catch {
                fputs("Phase 3 soak failed: \(error)\n", stderr)
            }
            try? FileManager.default.removeItem(at: root)
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func runProbe() {
        let alert = NSAlert()
        alert.messageText = "ScreenRecall"
        alert.informativeText = "将分别截取当前所有可采集显示器，测量 JPEG/HEIC 编码和图片尺寸。测试图片仅写入临时目录，验证后立即删除；报告不含屏幕内容。是否开始？"
        alert.addButton(withTitle: "开始验证")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let result = try await PlatformProbe.run()
                let output = try JSONEncoder.pretty.encode(result)
                let report = FileManager.default.temporaryDirectory.appendingPathComponent("screenrecall-platform-probe.json")
                try output.write(to: report, options: .atomic)
                showResult("验证完成：\(result.displays.count) 块屏幕。报告：\(report.path)")
            } catch {
                showResult("验证失败：\(error.localizedDescription)")
            }
        }
    }

    private func showResult(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ScreenRecall"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func quitApp() {
        Task {
            maintenanceTask?.cancel()
            systemEvents?.stop()
            await coordinator?.stop()
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct EngineSmokeReport: Encodable {
    let batchCount: Int
    let startedAt: [String]
    let statuses: [String]
    let expectedCounts: [Int]
    let succeededCounts: [Int]
    let skippedBusy: Int
    let skippedUnavailable: Int
}

private struct StorageSmokeReport: Encodable {
    let batchCountBeforeClear: Int
    let batchStatuses: [String]
    let readyAssetsBeforeClear: Int
    let allFilesExisted: Bool
    let bytesBeforeClear: Int64
    let batchCountAfterClear: Int
    let bytesAfterClear: Int64
}

private struct Phase3SoakReport: Encodable {
    let elapsedSeconds: Double
    let batchCount: Int
    let statuses: [String]
    let totalBytes: Int64
    let readyAssets: Int
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
