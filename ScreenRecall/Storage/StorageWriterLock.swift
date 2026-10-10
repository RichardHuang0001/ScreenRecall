import Darwin
import Foundation

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum StorageLockError: LocalizedError {
    case alreadyOpen
    var errorDescription: String? { "此历史目录已有一个 ScreenRecall 写入进程" }
}

/// 防止两个应用实例同时写同一数据库并绕开进程内的清空代次屏障。
final class StorageWriterLock {
    private let descriptor: Int32

    init(root: URL) throws {
        let path = root.appendingPathComponent(".writer.lock").path
        let fd = path.withCString { Darwin.open($0, O_CREAT | O_RDWR, 0o600) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard systemFlock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { throw StorageLockError.alreadyOpen }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit {
        _ = systemFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
