import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Date & Status Formatting

@MainActor
private enum HistoryDateText {
    static let fullFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return value
    }()

    static let timeFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "HH:mm:ss"
        return value
    }()

    static func string(_ date: Date) -> String { fullFormatter.string(from: date) }
    static func timeOnly(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func relativeString(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 10 { return "刚刚" }
        if elapsed < 60 { return "\(elapsed) 秒前" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if Calendar.current.isDateInToday(date) { return "\(hours) 小时前" }
        if Calendar.current.isDateInYesterday(date) {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            return "昨天 \(df.string(from: date))"
        }
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        return df.string(from: date)
    }

    static func status(_ value: String) -> String {
        switch value {
        case "complete": "完整"
        case "partial": "部分成功"
        case "failed": "失败"
        case "interrupted": "已中断"
        case "skipped": "已跳过"
        default: value
        }
    }
}

// MARK: - Quick Time Filters

enum HistoryTimeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case today = "今天"
    case past1Hour = "近 1 小时"
    case past4Hours = "近 4 小时"
    case custom = "指定时间…"

    var id: String { rawValue }
}

// MARK: - History View Model

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var batches: [StoredBatch] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var oldestDate: Date?
    @Published private(set) var totalBatches: Int = 0

    @Published var activeFilter: HistoryTimeFilter = .all
    @Published var selectedCustomDate: Date = Date()

    let sink: PersistentCaptureSink
    let loader: HistoryImageLoader
    let cache = HistoryThumbnailCache()
    private var cursor: HistoryCursor?
    private var generation = 0

    init(sink: PersistentCaptureSink) {
        self.sink = sink
        loader = HistoryImageLoader(sink: sink)
    }

    func reload(before date: Date? = nil) async {
        generation += 1
        cursor = date.map { HistoryCursor(startedAt: $0, id: "") }
        batches = []
        hasMore = true
        isLoading = false
        errorMessage = nil
        await loadMore()
    }

    func applyFilter(_ filter: HistoryTimeFilter) async {
        activeFilter = filter
        let now = Date()
        switch filter {
        case .all:
            await reload(before: nil)
        case .today:
            let startOfToday = Calendar.current.startOfDay(for: now)
            await reload(before: nil)
            // Filter local list to today
            batches = batches.filter { $0.startedAt >= startOfToday }
        case .past1Hour:
            let cutoff = now.addingTimeInterval(-3600)
            await reload(before: nil)
            batches = batches.filter { $0.startedAt >= cutoff }
        case .past4Hours:
            let cutoff = now.addingTimeInterval(-14400)
            await reload(before: nil)
            batches = batches.filter { $0.startedAt >= cutoff }
        case .custom:
            await reload(before: selectedCustomDate)
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let requestGeneration = generation
        do {
            let page = try await sink.history(limit: 50, before: cursor)
            guard requestGeneration == generation else { return }
            batches.append(contentsOf: page)
            cursor = page.last?.cursor
            hasMore = page.count == 50
            let status = try await sink.status()
            storageBytes = status.totalBytes
            oldestDate = status.oldestAvailableAt
            totalBatches = status.batchCount
        } catch {
            if requestGeneration == generation { errorMessage = error.localizedDescription }
        }
        if requestGeneration == generation { isLoading = false }
    }

    /// Called only when a capture finishes while the window is open; no polling timer.
    func refreshLatest() async {
        guard !isLoading else { return }
        let requestGeneration = generation
        do {
            let recent = try await sink.history(limit: 10)
            guard requestGeneration == generation else { return }
            let known = Set(batches.map(\.id))
            let added = recent.filter { !known.contains($0.id) }
            if !added.isEmpty {
                batches.insert(contentsOf: added, at: 0)
                let status = try await sink.status()
                storageBytes = status.totalBytes
                oldestDate = status.oldestAvailableAt
                totalBatches = status.batchCount
            }
        } catch { /* Explicit refresh remains available in the header. */ }
    }

    func clearForClose() {
        generation += 1
        batches = []
        cache.clear()
    }
}

// MARK: - Settings & Actions

struct HistorySettings {
    let excludedBundleIDs: Set<String>
    let retentionHours: Int
    let maximumGiB: Int
    let intervalSeconds: Int
    let loginAtStart: Bool

    init(excludedBundleIDs: Set<String>, retentionHours: Int, maximumGiB: Int,
         intervalSeconds: Int = 45, loginAtStart: Bool) {
        self.excludedBundleIDs = excludedBundleIDs
        self.retentionHours = retentionHours
        self.maximumGiB = maximumGiB
        self.intervalSeconds = intervalSeconds
        self.loginAtStart = loginAtStart
    }
}

struct HistoryActions {
    let start: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let captureNow: () -> Void
    let saveSettings: (Set<String>, Int, Int, Int) -> Void
    let setLoginAtStart: (Bool) -> Bool
    let clearHistory: () -> Void
    let openDataFolder: () -> Void
    let runProbe: () -> Void
    let quit: () -> Void

    @MainActor static let preview = HistoryActions(
        start: {}, pause: {}, resume: {}, captureNow: {},
        saveSettings: { _, _, _, _ in }, setLoginAtStart: { $0 }, clearHistory: {},
        openDataFolder: {}, runProbe: {}, quit: {})
}

@MainActor
final class HistoryControls: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var description = "未启动"
    @Published private(set) var lastBatch: String?
    @Published private(set) var intervalSeconds: Int = 45

    func update(state: CaptureState, description: String, lastBatch: String?, intervalSeconds: Int = 45) {
        self.state = state
        self.description = description
        self.lastBatch = lastBatch
        self.intervalSeconds = intervalSeconds
    }
}

// MARK: - Running App Detector

struct RunningAppItem: Identifiable, Hashable {
    let id: String // bundleIdentifier
    let name: String
    let icon: NSImage?
}

@MainActor
enum RunningAppDetector {
    static func currentApps() -> [RunningAppItem] {
        let apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                $0.bundleIdentifier != nil &&
                $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        var unique: [String: RunningAppItem] = [:]
        for app in apps {
            if let bid = app.bundleIdentifier, unique[bid] == nil {
                unique[bid] = RunningAppItem(id: bid, name: app.localizedName ?? bid, icon: app.icon)
            }
        }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Window Controller

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryViewModel
    let controls = HistoryControls()
    var onClose: (() -> Void)?

    init(sink: PersistentCaptureSink, settings: HistorySettings, actions: HistoryActions,
         onClose: @escaping () -> Void) {
        model = HistoryViewModel(sink: sink)
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ScreenRecall"
        window.minSize = NSSize(width: 840, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(model: model, controls: controls,
                                                                settings: settings, actions: actions))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func saveSnapshot(to url: URL) throws {
        guard let view = window?.contentView else { throw CocoaError(.fileWriteUnknown) }
        try Self.render(view, to: url)
    }

    func saveSettingsSnapshot(to url: URL) throws {
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        preview.contentView = NSHostingView(rootView: SettingsView(
            settings: HistorySettings(excludedBundleIDs: ["com.apple.Safari"], retentionHours: 24,
                                      maximumGiB: 2, intervalSeconds: 45, loginAtStart: false),
            actions: .preview) { _ in })
        preview.orderFront(nil)
        defer { preview.close() }
        guard let view = preview.contentView else { throw CocoaError(.fileWriteUnknown) }
        try Self.render(view, to: url)
    }

    private static func render(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    func windowWillClose(_ notification: Notification) {
        model.clearForClose()
        window?.contentView = nil
        onClose?()
        onClose = nil
    }
}

// MARK: - Selected Asset Model

private struct SelectedHistoryAsset: Identifiable {
    let id: String
    let batchID: String
    let displayOrder: Int
    let date: Date
    let displayCount: Int
}

// MARK: - Main History View

private struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var controls: HistoryControls
    let actions: HistoryActions
    @State private var currentSettings: HistorySettings
    @State private var selection: SelectedHistoryAsset?
    @State private var showingSettings = false
    @State private var showCustomDatePicker = false

    init(model: HistoryViewModel, controls: HistoryControls, settings: HistorySettings, actions: HistoryActions) {
        self.model = model
        self.controls = controls
        self.actions = actions
        _currentSettings = State(initialValue: settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            insightAndFilterBar
            if showCustomDatePicker {
                customDateBar
            }
            Divider()
            timelineContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.reload() }
        .sheet(item: $selection) { selected in
            HistoryPreview(asset: selected, sink: model.sink, loader: model.loader)
                .frame(minWidth: 880, minHeight: 620)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: currentSettings, actions: actions) { currentSettings = $0 }
        }
    }

    // MARK: Header Bar

    private var headerBar: some View {
        HStack(spacing: 16) {
            // App Branding Icon with modern gradient
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.85), Color.indigo.opacity(0.9)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .shadow(color: .blue.opacity(0.25), radius: 6, x: 0, y: 2)
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("ScreenRecall").font(.title3.weight(.bold))
                    Text("屏幕历史").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 7) {
                    // Status Pill
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(controls.description).font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12), in: Capsule())

                    Text("· 每 \(controls.intervalSeconds) 秒记录")
                        .font(.caption).foregroundStyle(.secondary)
                    if let lastBatch = controls.lastBatch {
                        Text("· \(lastBatch)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Header Actions
            HStack(spacing: 10) {
                Button { actions.captureNow() } label: {
                    Label("立即记录", systemImage: "camera")
                }
                .disabled(controls.state != .ready)
                .help("立即执行一批双屏截图（快捷键 ⌘R）")

                Button(primaryActionTitle) { performPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(primaryActionTint)
                    .disabled(controls.state == .capturing || controls.state == .pausedBySystem)

                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                }
                .help("打开设置")
                .accessibilityLabel("打开设置")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    // MARK: Insight and Filter Bar

    private var insightAndFilterBar: some View {
        HStack(spacing: 16) {
            // Storage Capacity Gauge
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("存储已用 \(ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file))")
                            .font(.caption.weight(.medium))
                        Text("/ \(currentSettings.maximumGiB) GiB")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("(\(storagePercentage)%)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(storagePercentage > 85 ? .orange : .secondary)
                    }
                    if let oldest = model.oldestDate {
                        Text("最早记录：\(HistoryDateText.relativeString(oldest))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // Mini Storage Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.5))
                        Capsule().fill(storagePercentage > 85 ? Color.orange : Color.accentColor)
                            .frame(width: max(3, geo.size.width * CGFloat(min(1.0, Double(storagePercentage) / 100.0))))
                    }
                }
                .frame(width: 60, height: 5)
            }

            Spacer()

            // Quick Time Filter Segmented Control
            HStack(spacing: 2) {
                ForEach(HistoryTimeFilter.allCases) { filter in
                    Button {
                        if filter == .custom {
                            showCustomDatePicker.toggle()
                        } else {
                            showCustomDatePicker = false
                            Task { await model.applyFilter(filter) }
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.weight(model.activeFilter == filter ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                (model.activeFilter == filter && (filter != .custom || showCustomDatePicker))
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(model.activeFilter == filter ? .accentColor : .primary)
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            // Refresh Button
            Button { Task { await model.reload() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .help("刷新历史记录")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: Custom Date Filter Inline Drawer

    private var customDateBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
            Text("查看此时间之前的屏幕历史：")
                .font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: $model.selectedCustomDate, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .frame(maxWidth: 220)
            Button("查询此时刻") {
                Task { await model.applyFilter(.custom) }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Button("返回最新") {
                showCustomDatePicker = false
                Task { await model.applyFilter(.all) }
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    // MARK: Timeline Content

    private var timelineContent: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.batches, id: \.id) { batch in
                    HistoryBatchCard(batch: batch, sink: model.sink, loader: model.loader, cache: model.cache) { id, order in
                        selection = SelectedHistoryAsset(id: id, batchID: batch.id, displayOrder: order,
                                                         date: batch.startedAt, displayCount: batch.expectedCount)
                    }
                    .onAppear {
                        if batch.id == model.batches.last?.id { Task { await model.loadMore() } }
                    }
                }
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("加载屏幕历史中…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red).padding()
                }
                if model.batches.isEmpty && !model.isLoading && model.errorMessage == nil {
                    emptyStateView
                }
                if !model.hasMore && !model.batches.isEmpty {
                    Text("— 已到最早记录 —")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 20)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("暂无屏幕历史")
                .font(.headline)
            Text("启用采集后，ScreenRecall 会在后台按指定间隔安全保存截图。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if controls.state != .ready && controls.state != .capturing {
                Button("启用记录") { actions.start() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private var storagePercentage: Int {
        let maxBytes = Int64(max(1, currentSettings.maximumGiB)) * 1024 * 1024 * 1024
        return min(100, Int((Double(model.storageBytes) / Double(maxBytes)) * 100))
    }

    private var statusColor: Color {
        switch controls.state {
        case .ready, .capturing: .green
        case .pausedByUser, .pausedBySystem, .idle: .orange
        default: .red
        }
    }

    private var primaryActionTitle: String {
        switch controls.state {
        case .ready, .capturing: "暂停记录"
        case .pausedByUser: "继续记录"
        default: "启用记录"
        }
    }

    private var primaryActionTint: Color {
        switch controls.state {
        case .ready, .capturing: .orange
        default: .accentColor
        }
    }

    private func performPrimaryAction() {
        switch controls.state {
        case .ready, .capturing: actions.pause()
        case .pausedByUser: actions.resume()
        default: actions.start()
        }
    }
}

// MARK: - History Batch Card

private struct HistoryBatchCard: View {
    let batch: StoredBatch
    let sink: PersistentCaptureSink
    let loader: HistoryImageLoader
    let cache: HistoryThumbnailCache
    let onPreview: (String, Int) -> Void
    @State private var frames: [StoredFrame]?
    @State private var loadError: String?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card Header
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(HistoryDateText.timeOnly(batch.startedAt))
                    .font(.headline.weight(.semibold))
                Text("· \(HistoryDateText.relativeString(batch.startedAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()

                // Status Badge
                HStack(spacing: 5) {
                    Circle()
                        .fill(batch.status == "complete" ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text("\(batch.successCount)/\(batch.expectedCount) 屏 · \(HistoryDateText.status(batch.status))")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (batch.status == "complete" ? Color.green : Color.orange).opacity(0.12),
                    in: Capsule()
                )
            }

            // Screen Frames Grid / Horizontal Scroll
            if let frames {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(frames, id: \.displayOrder) { frame in
                        HistoryFrameTile(frame: frame, batchDate: batch.startedAt, sink: sink,
                                         loader: loader, cache: cache, onPreview: onPreview)
                    }
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.red).font(.caption)
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(height: 160)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.45) : Color.gray.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.06 : 0.02), radius: 6, x: 0, y: 2)
        .onHover { isHovered = $0 }
        .task(id: batch.id) {
            do {
                let loaded = try await sink.frames(batchID: batch.id)
                guard !Task.isCancelled else { return }
                frames = loaded
            } catch { loadError = error.localizedDescription }
        }
        .onDisappear { frames = nil; loadError = nil }
    }
}

// MARK: - History Frame Tile

private struct HistoryFrameTile: View {
    let frame: StoredFrame
    let batchDate: Date
    let sink: PersistentCaptureSink
    let loader: HistoryImageLoader
    let cache: HistoryThumbnailCache
    let onPreview: (String, Int) -> Void
    @State private var image: DecodedHistoryImage?
    @State private var failed = false
    @State private var isTileHovered = false
    @State private var copiedFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(screenLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if copiedFeedback {
                    Text("已复制")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
            }

            if let assetID = frame.assetID {
                ZStack(alignment: .bottomTrailing) {
                    Button { onPreview(assetID, frame.displayOrder) } label: {
                        Group {
                            if let image {
                                Image(decorative: image.image, scale: 1)
                                    .resizable()
                                    .scaledToFit()
                            } else if failed {
                                Text("图片不可读取").foregroundStyle(.red).font(.caption)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(height: 170)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    // Hover Overlay Quick Actions
                    if isTileHovered && image != nil {
                        HStack(spacing: 6) {
                            Button { Task { await copyImage(assetID: assetID) } } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                                    .padding(5)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("复制图片到剪贴板")

                            Button { onPreview(assetID, frame.displayOrder) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2)
                                    .padding(5)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("放大查看")
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.35)))
                .onHover { isTileHovered = $0 }
                .task(id: assetID) {
                    if let cached = cache.image(for: assetID) { image = cached; return }
                    do {
                        let decoded = try await loader.load(assetID: assetID, maximumPixelSize: 480)
                        guard !Task.isCancelled else { return }
                        cache.insert(decoded, for: assetID)
                        image = decoded
                    } catch { if !Task.isCancelled { failed = true } }
                }
                .onDisappear { image = nil }
            } else {
                Text(frame.error ?? frame.status)
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var screenLabel: String {
        let orderText = frame.displayOrder == 0 ? "主屏幕 (屏幕 1)" : "屏幕 \(frame.displayOrder + 1)"
        return "\(orderText)\(frame.isMirrored ? " · 镜像" : "")"
    }

    private func copyImage(assetID: String) async {
        do {
            let (data, ext) = try await HistoryAssetActions.originalData(assetID: assetID, sink: sink)
            NSPasteboard.general.clearContents()
            let type = UTType(filenameExtension: ext)?.identifier ?? UTType.jpeg.identifier
            _ = NSPasteboard.general.setData(data, forType: .init(type))
            withAnimation { copiedFeedback = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { copiedFeedback = false }
        } catch { }
    }
}

// MARK: - Immersive History Preview

private struct HistoryPreview: View {
    let asset: SelectedHistoryAsset
    let sink: PersistentCaptureSink
    let loader: HistoryImageLoader
    @Environment(\.dismiss) private var dismiss
    @State private var image: DecodedHistoryImage?
    @State private var message: String?
    @State private var messageIsError = false
    @State private var fitToWindow = true
    @State private var copiedSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            // Floating Toolbar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("屏幕 \(asset.displayOrder + 1)")
                            .font(.headline.weight(.bold))
                        Text("· \(HistoryDateText.string(asset.date))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let image {
                        Text("\(image.image.width) × \(image.image.height) 像素")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Actions Group
                Button { fitToWindow.toggle() } label: {
                    Label(fitToWindow ? "适合窗口" : "实际大小",
                          systemImage: fitToWindow ? "arrow.down.right.and.arrow.up.left" : "viewfinder")
                }
                .controlSize(.small)

                Button { Task { await copyImage() } } label: {
                    Label(copiedSuccess ? "已复制" : "复制图片",
                          systemImage: copiedSuccess ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .foregroundColor(copiedSuccess ? .green : .primary)

                Button { Task { await exportImage() } } label: {
                    Label("导出…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)

                Button { Task { await revealInFinder() } } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .controlSize(.small)

                Divider().frame(height: 18)

                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(messageIsError ? .red : .secondary)
                    .padding(.vertical, 6)
            }

            Divider()

            // Preview Scroll Area
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        let cg = image.image
                        if fitToWindow {
                            Image(decorative: cg, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .padding(12)
                        } else {
                            Image(decorative: cg, scale: 1)
                                .resizable()
                                .frame(width: CGFloat(cg.width), height: CGFloat(cg.height))
                                .padding(24)
                        }
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在读取原图…").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(height: 480)
                    }
                }
            }
            .background(Color.black.opacity(0.85))
        }
        .task {
            do { image = try await loader.load(assetID: asset.id, maximumPixelSize: 4096) }
            catch { if !Task.isCancelled { message = error.localizedDescription; messageIsError = true } }
        }
        .onDisappear { image = nil }
    }

    private func revealInFinder() async {
        do {
            let url = try await sink.acquireAssetURL(asset.id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            await sink.releaseAsset(asset.id)
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    private func copyImage() async {
        do {
            let (data, extensionName) = try await HistoryAssetActions.originalData(assetID: asset.id, sink: sink)
            NSPasteboard.general.clearContents()
            let pasteboardType = UTType(filenameExtension: extensionName)?.identifier ?? UTType.jpeg.identifier
            guard NSPasteboard.general.setData(data, forType: .init(pasteboardType)) else {
                throw HistoryImageError.cannotDecode
            }
            withAnimation { copiedSuccess = true }
            message = "已复制原图到剪贴板"
            messageIsError = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { copiedSuccess = false }
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    private func exportImage() async {
        do {
            let url = try await sink.acquireAssetURL(asset.id)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "ScreenRecall-\(Int(asset.date.timeIntervalSince1970))-Screen\(asset.displayOrder + 1).\(url.pathExtension)"
            if let type = UTType(filenameExtension: url.pathExtension) { panel.allowedContentTypes = [type] }
            let response = panel.runModal()
            await sink.releaseAsset(asset.id)
            guard response == .OK, let destination = panel.url else { return }
            try await HistoryAssetActions.export(assetID: asset.id, sink: sink, to: destination)
            message = "已导出至 \(destination.lastPathComponent)"
            messageIsError = false
        } catch { message = error.localizedDescription; messageIsError = true }
    }
}

// MARK: - Modern Settings View with Tabs

private struct SettingsView: View {
    let settings: HistorySettings
    let actions: HistoryActions
    let onUpdate: (HistorySettings) -> Void
    @Environment(\.dismiss) private var dismiss

    enum SettingsTab: String, CaseIterable, Identifiable {
        case capture = "定时采集"
        case privacy = "隐私排除"
        case storage = "本地存储"
        case general = "通用与系统"
        var id: String { rawValue }
    }

    @State private var currentTab: SettingsTab = .capture
    @State private var excludedIDs: Set<String>
    @State private var manualBundleIDText: String
    @State private var retentionHours: Int
    @State private var maximumGiB: Int
    @State private var intervalSeconds: Int
    @State private var loginAtStart: Bool
    @State private var errorMessage: String?
    @State private var runningApps: [RunningAppItem] = []
    @State private var showClearConfirmation = false
    @State private var screenRecordingAuthorized = false

    private let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    init(settings: HistorySettings, actions: HistoryActions,
         onUpdate: @escaping (HistorySettings) -> Void) {
        self.settings = settings
        self.actions = actions
        self.onUpdate = onUpdate
        _excludedIDs = State(initialValue: settings.excludedBundleIDs)
        _manualBundleIDText = State(initialValue: settings.excludedBundleIDs.sorted().joined(separator: "\n"))
        _retentionHours = State(initialValue: settings.retentionHours)
        _maximumGiB = State(initialValue: settings.maximumGiB)
        _intervalSeconds = State(initialValue: settings.intervalSeconds)
        _loginAtStart = State(initialValue: settings.loginAtStart)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with Tab Picker
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("偏好设置").font(.title2.weight(.bold))
                    Text("自定义记录间隔、排除应用与本地存储策略").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(22)

            // Segmented Tab Picker
            Picker("", selection: $currentTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 22)
            .padding(.bottom, 12)

            Divider()

            // Tab Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch currentTab {
                    case .capture:
                        captureTab
                    case .privacy:
                        privacyTab
                    case .storage:
                        storageTab
                    case .general:
                        generalTab
                    }
                }
                .padding(24)
            }

            if let errorMessage {
                Divider()
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.vertical, 8)
            }
        }
        .frame(width: 620, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            runningApps = RunningAppDetector.currentApps()
            refreshScreenRecordingAuthorization()
        }
        .onChange(of: currentTab) { _, tab in
            if tab == .capture { refreshScreenRecordingAuthorization() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if currentTab == .capture { refreshScreenRecordingAuthorization() }
        }
        .alert("确定清空全部屏幕历史？", isPresented: $showClearConfirmation) {
            Button("永久清空", role: .destructive) {
                dismiss()
                DispatchQueue.main.async { actions.clearHistory() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作将删除本机保存的所有截图和数据库记录，无法恢复。")
        }
    }

    // MARK: Capture Tab

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "屏幕录制授权", icon: "lock.shield") {
                HStack(spacing: 9) {
                    Image(systemName: screenRecordingAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(screenRecordingAuthorized ? Color.green : Color.orange)
                    Text(screenRecordingAuthorized ? "已授权，可以记录屏幕" : "未授权，暂不能记录屏幕")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(screenRecordingAuthorized ? Color.green : Color.orange)
                    Spacer()
                    Link(screenRecordingAuthorized ? "管理授权" : "前往授权", destination: screenRecordingSettingsURL)
                        .font(.subheadline)
                }
                Text("请在 macOS「隐私与安全性」→「屏幕与系统音频录制」中允许 ScreenRecall。若列表中没有本应用，点列表下方的“+”并选择“应用程序”中的 ScreenRecall。返回此页后状态会自动更新；如系统要求重启，请按提示操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsCard(title: "定时记录频率", icon: "timer") {
                HStack {
                    Text("自动截图间隔")
                    Spacer()
                    Picker("", selection: $intervalSeconds) {
                        Text("15 秒（高频记录）").tag(15)
                        Text("30 秒（密集）").tag(30)
                        Text("45 秒（推荐默认）").tag(45)
                        Text("60 秒（1 分钟）").tag(60)
                        Text("120 秒（2 分钟）").tag(120)
                        Text("300 秒（5 分钟）").tag(300)
                    }
                    .frame(width: 190)
                }
                Divider()
                Text("ScreenRecall 仅在指定间隔唤醒极短时间进行屏幕捕获，平时不占用 CPU 资源。关闭窗口时后台记录持续运行。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            settingsCard(title: "多显示器支持", icon: "display.2") {
                Text("自动检测所有已连接的显示屏并逐屏记录。在多屏环境下，每个时间点均会保存完整的屏幕阵列。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Privacy Tab

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "一键排除运行中的应用", icon: "hand.raised.fill") {
                quickAppExclusionContent
            }
            settingsCard(title: "已排除的应用 Bundle ID", icon: "list.bullet.rectangle") {
                manualBundleIDContent
            }
        }
    }

    @ViewBuilder
    private var quickAppExclusionContent: some View {
        Text("排除的应用窗口在截图时将被自动滤除。点击下方快速添加：")
            .font(.caption).foregroundStyle(.secondary)

        if runningApps.isEmpty {
            Text("未检测到前台运行的其他应用").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(runningApps) { app in
                        runningAppButton(for: app)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func runningAppButton(for app: RunningAppItem) -> some View {
        let isExcluded = excludedIDs.contains(app.id)
        Button {
            toggleExclusion(app.id)
        } label: {
            HStack(spacing: 6) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(app.name).font(.caption.weight(.medium))
                Image(systemName: isExcluded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption)
                    .foregroundStyle(isExcluded ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isExcluded ? Color.green.opacity(0.12) : Color.gray.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var manualBundleIDContent: some View {
        TextEditor(text: $manualBundleIDText)
            .font(.system(.body, design: .monospaced))
            .frame(height: 85)
            .padding(6)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: manualBundleIDText) { _, val in
                if let parsed = AppPreferences.parseBundleIDs(val) {
                    excludedIDs = parsed
                }
            }

        HStack {
            Text("每行一个 Bundle ID，例如 com.apple.Safari。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("当前排除 \(excludedIDs.count) 个应用")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }

        Divider()
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "shield.checkered").foregroundStyle(.blue).font(.caption)
            Text("保存排除名单时，将立刻废弃正在采集的批次并生效新规则，先前历史继续保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Storage Tab

    private var storageTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "保留策略", icon: "externaldrive") {
                HStack {
                    Text("最长保留时间")
                    Spacer()
                    Picker("", selection: $retentionHours) {
                        ForEach([6, 12, 24, 48, 72, 168], id: \.self) {
                            Text($0 >= 24 ? "\($0 / 24) 天 (\($0) 小时)" : "\($0) 小时").tag($0)
                        }
                    }
                    .frame(width: 170)
                }

                HStack {
                    Text("磁盘容量上限")
                    Spacer()
                    Picker("", selection: $maximumGiB) {
                        ForEach([1, 2, 4, 8, 16, 32], id: \.self) { Text("\($0) GiB").tag($0) }
                    }
                    .frame(width: 170)
                }

                Divider()
                Text("先达到的限制优先执行。当超过上限时，后台会在空闲期间以事务分批安全清理最早的截图。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            settingsCard(title: "数据维护", icon: "wrench.and.screwdriver") {
                HStack(spacing: 12) {
                    Button { actions.openDataFolder() } label: {
                        Label("打开本地数据目录", systemImage: "folder")
                    }
                    Button { actions.runProbe() } label: {
                        Label("运行平台诊断…", systemImage: "stethoscope")
                    }
                    Spacer()
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Label("清空全部历史…", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(title: "系统与自启", icon: "power") {
                Toggle("登录时自动启动 ScreenRecall", isOn: $loginAtStart)
                    .onChange(of: loginAtStart) { _, enabled in
                        let actual = actions.setLoginAtStart(enabled)
                        if actual != enabled { loginAtStart = actual }
                        onUpdate(HistorySettings(excludedBundleIDs: excludedIDs,
                            retentionHours: retentionHours, maximumGiB: maximumGiB,
                            intervalSeconds: intervalSeconds, loginAtStart: actual))
                    }
            }

            settingsCard(title: "关于 ScreenRecall", icon: "info.circle") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("ScreenRecall").font(.headline)
                        Text("v0.6.5 (原生 macOS 应用)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("隐私优先的本地轻量屏幕历史记录工具。所有截图仅保存在本机私有沙盒，零云端上传，极低功耗。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button("退出 ScreenRecall", role: .destructive) { actions.quit() }
                        .buttonStyle(.plain).foregroundStyle(.red)
                    Spacer()
                }
            }
        }
    }

    // MARK: Helpers

    private func refreshScreenRecordingAuthorization() {
        screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    }

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, icon: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary.opacity(0.35)))
        }
    }

    private func toggleExclusion(_ bundleID: String) {
        if excludedIDs.contains(bundleID) {
            excludedIDs.remove(bundleID)
        } else {
            excludedIDs.insert(bundleID)
        }
        manualBundleIDText = excludedIDs.sorted().joined(separator: "\n")
    }

    private func saveAndClose() {
        guard let ids = AppPreferences.parseBundleIDs(manualBundleIDText) else {
            errorMessage = "Bundle ID 格式无效，请逐行填写，例如 com.apple.Safari。"
            return
        }
        actions.saveSettings(ids, retentionHours, maximumGiB, intervalSeconds)
        onUpdate(HistorySettings(excludedBundleIDs: ids, retentionHours: retentionHours,
                                 maximumGiB: maximumGiB, intervalSeconds: intervalSeconds,
                                 loginAtStart: loginAtStart))
        dismiss()
    }
}
