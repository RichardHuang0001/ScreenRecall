import Foundation

enum HistoryAssetActions {
    static func originalData(assetID: String, sink: PersistentCaptureSink) async throws -> (Data, String) {
        let url = try await sink.acquireAssetURL(assetID)
        do {
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            await sink.releaseAsset(assetID)
            return (data, url.pathExtension)
        } catch {
            await sink.releaseAsset(assetID)
            throw error
        }
    }

    static func export(assetID: String, sink: PersistentCaptureSink, to destination: URL) async throws {
        let source = try await sink.acquireAssetURL(assetID)
        do {
            try await Task.detached(priority: .userInitiated) {
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ScreenRecall-\(UUID().uuidString).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            }.value
            await sink.releaseAsset(assetID)
        } catch {
            await sink.releaseAsset(assetID)
            throw error
        }
    }
}
