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

    func clearForClose() {
        generation += 1
        batches = []
        cache.clear()
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryViewModel
    var onClose: (() -> Void)?

    init(sink: PersistentCaptureSink, onClose: @escaping () -> Void) {
        model = HistoryViewModel(sink: sink)
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 730),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ScreenRecall 历史"
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

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
    @State private var selectedDate = Date()
    @State private var selection: SelectedHistoryAsset?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("屏幕历史").font(.title2).bold()
                Spacer()
                Text("占用 \(ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Button("刷新") { Task { await model.reload() } }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            HStack(spacing: 8) {
                Text("定位至")
                DatePicker("时间", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().frame(maxWidth: 250)
                Button("此前记录") { Task { await model.reload(before: selectedDate) } }
                Button("最新") { Task { await model.reload() } }
                Spacer()
                Text("每次加载 50 个时间节点").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
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
        }
        .task { await model.reload() }
        .sheet(item: $selection) { selected in
            HistoryPreview(asset: selected, sink: model.sink, loader: model.loader)
                .frame(minWidth: 760, minHeight: 540)
        }
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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
