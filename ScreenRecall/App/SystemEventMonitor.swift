import AppKit
import Foundation

/// 系统通知只变更状态，不创建截图或清理计时器。
@MainActor
final class SystemEventMonitor {
    private var tokens: [NSObjectProtocol] = []
    private var memorySource: DispatchSourceMemoryPressure?
    private let coordinator: CaptureCoordinator
    private let onMaintenanceAllowed: @MainActor @Sendable (Bool) -> Void
    private var memoryNormal = true
    private var thermalNormal = true

    init(coordinator: CaptureCoordinator, onMaintenanceAllowed: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.coordinator = coordinator
        self.onMaintenanceAllowed = onMaintenanceAllowed
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.suspend("sleep") }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.resume("sleep") }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.suspend("screenSleep") }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.resume("screenSleep") }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.suspend("session") }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.resume("session") }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }
            Task {
                await self.coordinator.suspendForSystem("displayChange")
                await self.coordinator.resumeFromSystem("displayChange")
            }
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.recheckPermission() }
        }
        observe(NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            self?.refreshThermalState()
        }
        refreshThermalState()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.memoryNormal = source.data.contains(.normal)
            self.onMaintenanceAllowed(self.memoryNormal && self.thermalNormal)
            if source.data.contains(.critical) { self.suspend("memoryPressure") }
            else { self.resume("memoryPressure") }
        }
        source.resume()
        memorySource = source
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor @Sendable () -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        })
    }

    private func suspend(_ reason: String) { Task { await coordinator.suspendForSystem(reason) } }
    private func resume(_ reason: String) { Task { await coordinator.resumeFromSystem(reason) } }

    private func refreshThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        thermalNormal = state == .nominal
        onMaintenanceAllowed(memoryNormal && thermalNormal)
        if state == .serious || state == .critical { suspend("thermal") }
        else { resume("thermal") }
    }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        memorySource?.cancel()
        memorySource = nil
    }
}
