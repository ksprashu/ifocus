import Foundation

public enum SecureFileStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidFilename(String)
    case insecureDirectory(String)
    case symlinkRefused(String)
    case notRegularFile(String)
    case wrongOwner(String)
    case insecurePermissions(String)
    case fileTooLarge(Int64)
    case posix(Int32, String)

    public var description: String {
        switch self {
        case .invalidFilename(let name):
            return "Invalid filename: \(name)"
        case .insecureDirectory(let reason):
            return "Insecure directory: \(reason)"
        case .symlinkRefused(let path):
            return "Symlink refused at \(path)"
        case .notRegularFile(let path):
            return "Not a regular file at \(path)"
        case .wrongOwner(let path):
            return "File not owned by current user at \(path)"
        case .insecurePermissions(let path):
            return "File is group- or world-writable at \(path)"
        case .fileTooLarge(let bytes):
            return "File exceeds 1 MiB limit (\(bytes) bytes)"
        case .posix(let code, let op):
            let msg = String(cString: strerror(code))
            return "POSIX error \(code) during \(op): \(msg)"
        }
    }
}

public struct SecureFileStore: Sendable {
    public static let maxFileSizeBytes: Int = 1_048_576

    public let directoryURL: URL

    public init(directoryURL: URL = SecureFileStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    public static func defaultDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("iFocus", isDirectory: true)
    }

    public func fileURL(for filename: String) throws -> URL {
        try validateFilename(filename)
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    public func read(_ filename: String) throws -> Data? {
        try validateFilename(filename)
        let dirPath = directoryURL.path
        guard let dirFD = try openDirectoryFD(path: dirPath, allowMissing: true) else {
            return nil
        }
        defer { _ = close(dirFD) }

        var dirStat = stat()
        if fstat(dirFD, &dirStat) != 0 {
            throw SecureFileStoreError.posix(errno, "fstat(\(dirPath))")
        }
        try validateDirectoryDescriptorStat(dirStat, path: dirPath)
        guard (dirStat.st_mode & 0o077) == 0 else {
            throw SecureFileStoreError.insecureDirectory("\(dirPath) has insecure group/other permissions")
        }

        let filePath = dirPath + "/" + filename
        let fd = openat(dirFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            if err == ENOENT {
                return nil
            }
            if err == ELOOP {
                throw SecureFileStoreError.symlinkRefused(filePath)
            }
            throw SecureFileStoreError.posix(err, "openat(\(filePath))")
        }
        defer { _ = close(fd) }

        var fileStat = stat()
        if fstat(fd, &fileStat) != 0 {
            throw SecureFileStoreError.posix(errno, "fstat(\(filePath))")
        }

        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw SecureFileStoreError.notRegularFile(filePath)
        }
        guard fileStat.st_uid == getuid() else {
            throw SecureFileStoreError.wrongOwner(filePath)
        }
        guard (fileStat.st_mode & 0o022) == 0 else {
            throw SecureFileStoreError.insecurePermissions(filePath)
        }
        guard fileStat.st_size >= 0 && fileStat.st_size <= Int64(Self.maxFileSizeBytes) else {
            throw SecureFileStoreError.fileTooLarge(fileStat.st_size)
        }

        var result = Data()
        if fileStat.st_size > 0 {
            result.reserveCapacity(Int(fileStat.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return 0 }
                return Foundation.read(fd, base, rawBuf.count)
            }
            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                throw SecureFileStoreError.posix(err, "read(\(filePath))")
            }
            if bytesRead == 0 {
                break
            }
            if result.count + bytesRead > Self.maxFileSizeBytes {
                throw SecureFileStoreError.fileTooLarge(Int64(result.count + bytesRead))
            }
            result.append(buffer, count: bytesRead)
        }
        return result
    }

    public func write(_ data: Data, to filename: String) throws {
        try validateFilename(filename)
        guard data.count <= Self.maxFileSizeBytes else {
            throw SecureFileStoreError.fileTooLarge(Int64(data.count))
        }
        try ensureDirectoryExists()

        let dirPath = directoryURL.path
        guard let dirFD = try openDirectoryFD(path: dirPath, allowMissing: false) else {
            throw SecureFileStoreError.posix(ENOENT, "open(\(dirPath))")
        }
        defer { _ = close(dirFD) }

        var dirStat = stat()
        if fstat(dirFD, &dirStat) != 0 {
            throw SecureFileStoreError.posix(errno, "fstat(\(dirPath))")
        }
        try validateDirectoryDescriptorStat(dirStat, path: dirPath)
        let perms = dirStat.st_mode & 0o777
        if (perms & 0o077) != 0 {
            if fchmod(dirFD, perms & ~0o077) != 0 {
                throw SecureFileStoreError.posix(errno, "fchmod(\(dirPath))")
            }
        }

        let tmpName = ".tmp." + UUID().uuidString
        let tmpPath = dirPath + "/" + tmpName
        let destPath = dirPath + "/" + filename

        let fd = openat(dirFD, tmpName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            throw SecureFileStoreError.posix(errno, "openat(\(tmpPath))")
        }

        var fdClosed = false
        do {
            try writeAll(data, to: fd, path: tmpPath)
            if fchmod(fd, 0o600) != 0 {
                throw SecureFileStoreError.posix(errno, "fchmod(\(tmpPath))")
            }
            if fsync(fd) != 0 {
                throw SecureFileStoreError.posix(errno, "fsync(\(tmpPath))")
            }
            if close(fd) != 0 {
                fdClosed = true
                throw SecureFileStoreError.posix(errno, "close(\(tmpPath))")
            }
            fdClosed = true

            if renameat(dirFD, tmpName, dirFD, filename) != 0 {
                throw SecureFileStoreError.posix(errno, "renameat(\(tmpPath) -> \(destPath))")
            }
            if fsync(dirFD) != 0 && errno != EINVAL && errno != ENOTSUP {
                throw SecureFileStoreError.posix(errno, "fsync(\(dirPath))")
            }
        } catch {
            if !fdClosed {
                _ = close(fd)
            }
            _ = unlinkat(dirFD, tmpName, 0)
            throw error
        }
    }

    public func ensureDirectoryExists() throws {
        let dirPath = directoryURL.path
        var dirStat = stat()
        if lstat(dirPath, &dirStat) == 0 {
            try validateDirectoryLstat(dirStat, path: dirPath, fixPermissions: true)
            return
        }
        let firstErr = errno
        guard firstErr == ENOENT else {
            throw SecureFileStoreError.posix(firstErr, "lstat(\(dirPath))")
        }

        let parentURL = directoryURL.deletingLastPathComponent()
        if !parentURL.path.isEmpty && parentURL.path != "/" {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        if mkdir(dirPath, 0o700) != 0 {
            let mkErr = errno
            if mkErr != EEXIST {
                throw SecureFileStoreError.posix(mkErr, "mkdir(\(dirPath))")
            }
        }

        if lstat(dirPath, &dirStat) != 0 {
            throw SecureFileStoreError.posix(errno, "lstat(\(dirPath))")
        }
        try validateDirectoryLstat(dirStat, path: dirPath, fixPermissions: true)
    }

    private func openDirectoryFD(path: String, allowMissing: Bool) throws -> Int32? {
        let dirFD = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dirFD >= 0 {
            return dirFD
        }
        let err = errno
        if allowMissing && err == ENOENT {
            return nil
        }
        if err == ELOOP {
            throw SecureFileStoreError.symlinkRefused(path)
        }
        if err == ENOTDIR {
            // Darwin returns ENOTDIR (not ELOOP) when O_DIRECTORY | O_NOFOLLOW hits a symlink.
            var lst = stat()
            if lstat(path, &lst) == 0 && (lst.st_mode & S_IFMT) == S_IFLNK {
                throw SecureFileStoreError.symlinkRefused(path)
            }
            throw SecureFileStoreError.insecureDirectory("\(path) is not a directory")
        }
        throw SecureFileStoreError.posix(err, "open(\(path))")
    }

    private func validateDirectoryDescriptorStat(_ st: stat, path: String) throws {
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw SecureFileStoreError.insecureDirectory("\(path) is not a directory")
        }
        guard st.st_uid == getuid() else {
            throw SecureFileStoreError.insecureDirectory("\(path) is not owned by current user")
        }
    }

    private func validateDirectoryLstat(_ st: stat, path: String, fixPermissions: Bool) throws {
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            if (st.st_mode & S_IFMT) == S_IFLNK {
                throw SecureFileStoreError.symlinkRefused(path)
            }
            throw SecureFileStoreError.insecureDirectory("\(path) is not a directory")
        }
        guard st.st_uid == getuid() else {
            throw SecureFileStoreError.insecureDirectory("\(path) is not owned by current user")
        }
        let perms = st.st_mode & 0o777
        if (perms & 0o077) != 0 && fixPermissions {
            let safePerms = perms & ~0o077
            if chmod(path, safePerms) != 0 {
                throw SecureFileStoreError.posix(errno, "chmod(\(path))")
            }
        }
    }

    private func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\0") else {
            throw SecureFileStoreError.invalidFilename(filename)
        }
    }

    private func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            while written < rawBuf.count {
                let n = Foundation.write(fd, base.advanced(by: written), rawBuf.count - written)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw SecureFileStoreError.posix(err, "write(\(path))")
                }
                if n == 0 {
                    throw SecureFileStoreError.posix(EIO, "write(\(path)) returned 0")
                }
                written += n
            }
        }
    }
}
