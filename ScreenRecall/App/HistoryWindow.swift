import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private enum HistoryDateText {
    static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return value
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
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

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var batches: [StoredBatch] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageBytes: Int64 = 0

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
            storageBytes = try await sink.status().totalBytes
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
                storageBytes = try await sink.status().totalBytes
            }
        } catch { /* Explicit refresh remains available in the header. */ }
    }

    func clearForClose() {
        generation += 1
        batches = []
        cache.clear()
    }
}

struct HistorySettings {
    let excludedBundleIDs: Set<String>
    let retentionHours: Int
    let maximumGiB: Int
    let loginAtStart: Bool
}

struct HistoryActions {
    let start: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let captureNow: () -> Void
    let saveSettings: (Set<String>, Int, Int) -> Void
    let setLoginAtStart: (Bool) -> Bool
    let clearHistory: () -> Void
    let openDataFolder: () -> Void
    let runProbe: () -> Void
    let quit: () -> Void

    @MainActor static let preview = HistoryActions(start: {}, pause: {}, resume: {}, captureNow: {},
        saveSettings: { _, _, _ in }, setLoginAtStart: { $0 }, clearHistory: {},
        openDataFolder: {}, runProbe: {}, quit: {})
}

@MainActor
final class HistoryControls: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var description = "未启动"
    @Published private(set) var lastBatch: String?

    func update(state: CaptureState, description: String, lastBatch: String?) {
        self.state = state
        self.description = description
        self.lastBatch = lastBatch
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryViewModel
    let controls = HistoryControls()
    var onClose: (() -> Void)?

    init(sink: PersistentCaptureSink, settings: HistorySettings, actions: HistoryActions,
         onClose: @escaping () -> Void) {
        model = HistoryViewModel(sink: sink)
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 730),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ScreenRecall"
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(model: model, controls: controls,
                                                                settings: settings, actions: actions))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    /// Explicit validation hook; never runs during normal background capture.
    func saveSnapshot(to url: URL) throws {
        guard let view = window?.contentView else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Self.render(view, to: url)
    }

    func saveSettingsSnapshot(to url: URL) throws {
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                               styleMask: [.titled], backing: .buffered, defer: false)
        preview.contentView = NSHostingView(rootView: SettingsView(
            settings: HistorySettings(excludedBundleIDs: ["com.apple.Safari"], retentionHours: 24,
                                      maximumGiB: 2, loginAtStart: false), actions: .preview) { _ in })
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

private struct SelectedHistoryAsset: Identifiable {
    let id: String
    let displayOrder: Int
    let date: Date
}

private struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var controls: HistoryControls
    let actions: HistoryActions
    @State private var currentSettings: HistorySettings
    @State private var selectedDate = Date()
    @State private var selection: SelectedHistoryAsset?
    @State private var showingSettings = false

    init(model: HistoryViewModel, controls: HistoryControls, settings: HistorySettings, actions: HistoryActions) {
        self.model = model
        self.controls = controls
        self.actions = actions
        _currentSettings = State(initialValue: settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("屏幕历史").font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(controls.description)
                        Text("· 每 45 秒记录")
                        if let lastBatch = controls.lastBatch { Text("· \(lastBatch)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { actions.captureNow() } label: { Label("立即记录", systemImage: "camera") }
                    .disabled(controls.state != .ready)
                Button(primaryActionTitle) { performPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .disabled(controls.state == .capturing || controls.state == .pausedBySystem)
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .help("设置")
                    .accessibilityLabel("打开设置")
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .background(.regularMaterial)
            Divider()
            HStack(spacing: 8) {
                Text("时间线").font(.headline)
                Spacer()
                Text("已使用 \(ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Divider().frame(height: 18)
                Text("定位至").foregroundStyle(.secondary)
                DatePicker("时间", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().frame(maxWidth: 250)
                Button("此前记录") { Task { await model.reload(before: selectedDate) } }
                Button("最新") { Task { await model.reload() } }
            }
            .controlSize(.small)
            .padding(.horizontal, 22).padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.batches, id: \.id) { batch in
                        HistoryBatchCard(batch: batch, sink: model.sink, loader: model.loader, cache: model.cache) { id, order in
                            selection = SelectedHistoryAsset(id: id, displayOrder: order, date: batch.startedAt)
                        }
                        .onAppear {
                            if batch.id == model.batches.last?.id { Task { await model.loadMore() } }
                        }
                    }
                    if model.isLoading { ProgressView().padding() }
                    if let message = model.errorMessage { Text(message).foregroundStyle(.red).padding() }
                    if model.batches.isEmpty && !model.isLoading && model.errorMessage == nil {
                        ContentUnavailableView("暂无屏幕历史", systemImage: "photo.on.rectangle", description: Text("启用采集后，记录会显示在这里。"))
                            .padding(.top, 90)
                    }
                    if !model.hasMore && !model.batches.isEmpty { Text("已到最早记录").foregroundStyle(.secondary).padding() }
                }
                .padding(16)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.reload() }
        .sheet(item: $selection) { selected in
            HistoryPreview(asset: selected, sink: model.sink, loader: model.loader)
                .frame(minWidth: 760, minHeight: 540)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: currentSettings, actions: actions) { currentSettings = $0 }
        }
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

    private func performPrimaryAction() {
        switch controls.state {
        case .ready, .capturing: actions.pause()
        case .pausedByUser: actions.resume()
        default: actions.start()
        }
    }
}

private struct SettingsView: View {
    let settings: HistorySettings
    let actions: HistoryActions
    let onUpdate: (HistorySettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var excludedIDs: String
    @State private var retentionHours: Int
    @State private var maximumGiB: Int
    @State private var loginAtStart: Bool
    @State private var errorMessage: String?

    init(settings: HistorySettings, actions: HistoryActions,
         onUpdate: @escaping (HistorySettings) -> Void) {
        self.settings = settings
        self.actions = actions
        self.onUpdate = onUpdate
        _excludedIDs = State(initialValue: settings.excludedBundleIDs.sorted().joined(separator: "\n"))
        _retentionHours = State(initialValue: settings.retentionHours)
        _maximumGiB = State(initialValue: settings.maximumGiB)
        _loginAtStart = State(initialValue: settings.loginAtStart)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置").font(.title2.weight(.semibold))
                    Text("调整记录范围与本地保留方式").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { saveAndClose() }.buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    settingsSection("采集", icon: "camera.viewfinder") {
                        HStack {
                            Text("自动记录间隔")
                            Spacer()
                            Text("45 秒").foregroundStyle(.secondary)
                        }
                        Text("应用仅在定时触发时采集；关闭历史窗口不会暂停记录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsSection("隐私", icon: "hand.raised") {
                        Text("排除的应用 Bundle ID")
                        TextEditor(text: $excludedIDs)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 72)
                            .padding(6)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        Text("每行填写一个，例如 com.apple.Safari；保存时会废弃正在采集的一批，新规则用于后续截图。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsSection("本地存储", icon: "externaldrive") {
                        Picker("最长保留", selection: $retentionHours) {
                            ForEach([6, 12, 24, 48], id: \.self) { Text("\($0) 小时").tag($0) }
                        }
                        Picker("容量上限", selection: $maximumGiB) {
                            ForEach([1, 2, 4], id: \.self) { Text("\($0) GiB").tag($0) }
                        }
                        Text("先达到的限制先执行；缩短限制后会在后台分批清理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    settingsSection("系统与数据", icon: "gearshape") {
                        Toggle("登录后启动 ScreenRecall", isOn: $loginAtStart)
                            .onChange(of: loginAtStart) { _, enabled in
                                let actual = actions.setLoginAtStart(enabled)
                                if actual != enabled { loginAtStart = actual }
                                onUpdate(HistorySettings(excludedBundleIDs: settings.excludedBundleIDs,
                                    retentionHours: settings.retentionHours, maximumGiB: settings.maximumGiB,
                                    loginAtStart: actual))
                            }
                        HStack(spacing: 10) {
                            Button("打开数据目录") { actions.openDataFolder() }
                            Button("平台验证…") { actions.runProbe() }
                            Spacer()
                            Button("清空全部历史…", role: .destructive) {
                                dismiss()
                                DispatchQueue.main.async { actions.clearHistory() }
                            }
                        }
                    }
                    HStack {
                        Button("退出 ScreenRecall") { actions.quit() }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(24)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
        .frame(width: 540, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, icon: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func saveAndClose() {
        guard let ids = AppPreferences.parseBundleIDs(excludedIDs) else {
            errorMessage = "Bundle ID 格式无效，请逐行填写，例如 com.apple.Safari。"
            return
        }
        actions.saveSettings(ids, retentionHours, maximumGiB)
        onUpdate(HistorySettings(excludedBundleIDs: ids, retentionHours: retentionHours,
                                 maximumGiB: maximumGiB, loginAtStart: loginAtStart))
        dismiss()
    }
}

private struct HistoryBatchCard: View {
    let batch: StoredBatch
    let sink: PersistentCaptureSink
    let loader: HistoryImageLoader
    let cache: HistoryThumbnailCache
    let onPreview: (String, Int) -> Void
    @State private var frames: [StoredFrame]?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(HistoryDateText.string(batch.startedAt)).font(.headline)
                Spacer()
                Text("\(batch.successCount)/\(batch.expectedCount) 屏 · \(HistoryDateText.status(batch.status))")
                    .foregroundColor(batch.status == "complete" ? .secondary : .orange)
            }
            if let frames {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(frames, id: \.displayOrder) { frame in
                            HistoryFrameTile(frame: frame, loader: loader, cache: cache, onPreview: onPreview)
                                .frame(width: 315)
                        }
                    }
                }
                .frame(height: 205)
            } else if let loadError {
                Text(loadError).foregroundStyle(.red)
            } else {
                ProgressView().frame(height: 205)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.5)))
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

private struct HistoryFrameTile: View {
    let frame: StoredFrame
    let loader: HistoryImageLoader
    let cache: HistoryThumbnailCache
    let onPreview: (String, Int) -> Void
    @State private var image: DecodedHistoryImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("屏幕 \(frame.displayOrder + 1)\(frame.isMirrored ? " · 镜像" : "")")
                .font(.subheadline).foregroundStyle(.secondary)
            if let assetID = frame.assetID {
                Button { onPreview(assetID, frame.displayOrder) } label: {
                    Group {
                        if let image {
                            Image(decorative: image.image, scale: 1).resizable().scaledToFit()
                        } else if failed {
                            Text("图片不可读取").foregroundStyle(.red)
                        } else { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: 175)
                    .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
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
                Text(frame.error ?? frame.status).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity).frame(height: 175)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct HistoryPreview: View {
    let asset: SelectedHistoryAsset
    let sink: PersistentCaptureSink
    let loader: HistoryImageLoader
    @Environment(\.dismiss) private var dismiss
    @State private var image: DecodedHistoryImage?
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("屏幕 \(asset.displayOrder + 1) · \(HistoryDateText.string(asset.date))")
                    .font(.headline)
                Spacer()
                Button("在 Finder 中显示") { Task { await revealInFinder() } }
                Button("复制图片") { Task { await copyImage() } }
                Button("导出…") { Task { await exportImage() } }
                Button("关闭") { dismiss() }
            }.padding(.horizontal, 16).padding(.top, 14)
            if let message { Text(message).foregroundColor(messageIsError ? .red : .secondary) }
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if let image {
                    Image(decorative: image.image, scale: 1).resizable()
                        .frame(width: CGFloat(image.image.width), height: CGFloat(image.image.height))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 420)
                }
            }
        }
        .task {
            do { image = try await loader.load(assetID: asset.id, maximumPixelSize: 2400) }
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
            guard NSPasteboard.general.setData(data, forType: .init(pasteboardType)) else { throw HistoryImageError.cannotDecode }
            message = "已复制到剪贴板"
            messageIsError = false
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    private func exportImage() async {
        do {
            let url = try await sink.acquireAssetURL(asset.id)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "ScreenRecall-\(Int(asset.date.timeIntervalSince1970)).\(url.pathExtension)"
            if let type = UTType(filenameExtension: url.pathExtension) { panel.allowedContentTypes = [type] }
            let response = panel.runModal()
            await sink.releaseAsset(asset.id)
            guard response == .OK, let destination = panel.url else { return }
            try await HistoryAssetActions.export(assetID: asset.id, sink: sink, to: destination)
            message = "已导出"
            messageIsError = false
        } catch { message = error.localizedDescription; messageIsError = true }
    }
}
