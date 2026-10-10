import Darwin
import Foundation
import ImageIO

struct StoragePaths {
    let root: URL
    let assets: URL
    let staging: URL
    let database: URL

    init(root: URL? = nil) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.root = root ?? support.appendingPathComponent("ScreenRecall", isDirectory: true)
        assets = self.root.appendingPathComponent("assets", isDirectory: true)
        staging = self.root.appendingPathComponent("staging", isDirectory: true)
        database = self.root.appendingPathComponent("history.sqlite")
        for directory in [self.root, assets, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

enum AssetStoreError: LocalizedError {
    case outsideRoot, invalidFile, crossVolume
    var errorDescription: String? {
        switch self {
        case .outsideRoot: "图片路径不在私有数据目录中"
        case .invalidFile: "暂存图片校验失败"
        case .crossVolume: "暂存目录与图片目录不在同一文件系统"
        }
    }
}

/// 同步文件操作，由 PersistentCaptureSink actor 串行调用。
struct AssetFileStore {
    let paths: StoragePaths

    func relativePath(assetID: UUID, date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd/HH"
        let suffix = format == "heic" ? "heic" : format == "png" ? "png" : "jpg"
        return "assets/\(formatter.string(from: date))/\(assetID.uuidString).\(suffix)"
    }

    func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."),
              relativePath.hasPrefix("assets/") || relativePath.hasPrefix("staging/") else {
            throw AssetStoreError.outsideRoot
        }
        return paths.root.appendingPathComponent(relativePath)
    }

    func stagingRelativePath(_ url: URL) throws -> String {
        let rootPath = paths.root.standardizedFileURL.path + "/"
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(rootPath), candidate.dropFirst(rootPath.count).hasPrefix("staging/") else {
            throw AssetStoreError.outsideRoot
        }
        return String(candidate.dropFirst(rootPath.count))
    }

    func verify(_ url: URL, width: Int, height: Int, bytes: Int64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == bytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == height,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width == width, decoded.height == height else {
            throw AssetStoreError.invalidFile
        }
    }

    func verifyFileSize(_ url: URL, bytes: Int64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == bytes else { throw AssetStoreError.invalidFile }
    }

    func moveStaged(_ source: URL, to relativePath: String) throws {
        let destination = try resolve(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.deletingLastPathComponent().path)
        let result = source.path.withCString { from in
            destination.path.withCString { to in Darwin.renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else {
            if errno == EXDEV { throw AssetStoreError.crossVolume }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func pruneEmptyAssetParents(of url: URL) throws {
        var directory = url.deletingLastPathComponent()
        while directory.standardizedFileURL.path.hasPrefix(paths.assets.standardizedFileURL.path + "/") {
            if !FileManager.default.fileExists(atPath: directory.path) {
                directory = directory.deletingLastPathComponent()
                continue
            }
            let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard children.isEmpty else { break }
            try FileManager.default.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
