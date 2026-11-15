import Foundation
import Testing
@testable import iFocusCore

@Suite("FileStore")
struct FileStoreTests {
    @Test("T34 secure file store permissions symlinks and size limit")
    func t34PermissionsSymlinksAndSizeLimit() throws {
        let tmpTemplate = "/tmp/ifocus-t34-XXXXXX"
        var buf = Array(tmpTemplate.utf8CString)
        guard let rootCStr = mkdtemp(&buf) else {
            Issue.record("mkdtemp failed")
            return
        }
        let rootURL = URL(fileURLWithPath: String(cString: rootCStr), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storeDir = rootURL.appendingPathComponent("store", isDirectory: true)
        let store = SecureFileStore(directoryURL: storeDir)
        let payload = Data("{\"hello\":true}".utf8)
        try store.write(payload, to: "test.json")

        // Verify 0700 dir and 0600 file permissions
        var dirSt = stat()
        #expect(lstat(storeDir.path, &dirSt) == 0)
        #expect((dirSt.st_mode & 0o777) == 0o700)

        let filePath = storeDir.appendingPathComponent("test.json").path
        var fileSt = stat()
        #expect(lstat(filePath, &fileSt) == 0)
        #expect((fileSt.st_mode & 0o777) == 0o600)
        #expect(try store.read("test.json") == payload)

        // Group-writable file refused
        #expect(chmod(filePath, 0o620) == 0)
        #expect(throws: SecureFileStoreError.insecurePermissions(filePath)) {
            _ = try store.read("test.json")
        }
        #expect(chmod(filePath, 0o600) == 0)

        // Symlink file refused
        let targetPath = rootURL.appendingPathComponent("target.json").path
        FileManager.default.createFile(atPath: targetPath, contents: payload)
        let symFilePath = storeDir.appendingPathComponent("link.json").path
        #expect(symlink(targetPath, symFilePath) == 0)
        #expect(throws: SecureFileStoreError.symlinkRefused(symFilePath)) {
            _ = try store.read("link.json")
        }

        // Oversized file (> 1 MiB) refused
        let bigData = Data(repeating: 0x41, count: SecureFileStore.maxFileSizeBytes + 1)
        let bigPath = storeDir.appendingPathComponent("big.json").path
        let bigFD = open(bigPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(bigFD >= 0)
        _ = bigData.withUnsafeBytes { raw in
            Foundation.write(bigFD, raw.baseAddress!, raw.count)
        }
        _ = close(bigFD)
        #expect(throws: SecureFileStoreError.fileTooLarge(Int64(bigData.count))) {
            _ = try store.read("big.json")
        }

        // Symlinked directory refused
        let symDirURL = rootURL.appendingPathComponent("symdir", isDirectory: true)
        #expect(symlink(storeDir.path, symDirURL.path) == 0)
        let symDirStore = SecureFileStore(directoryURL: symDirURL)
        #expect(throws: SecureFileStoreError.symlinkRefused(symDirURL.path)) {
            _ = try symDirStore.read("test.json")
        }
    }

    @Test("T71 directory permission hardening rejects loose read dirs and repairs on write")
    func t71DirectoryPermissionsOnReadAndWrite() throws {
        let tmpTemplate = "/tmp/ifocus-t71-XXXXXX"
        var buf = Array(tmpTemplate.utf8CString)
        guard let rootCStr = mkdtemp(&buf) else {
            Issue.record("mkdtemp failed")
            return
        }
        let rootURL = URL(fileURLWithPath: String(cString: rootCStr), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let storeDir = rootURL.appendingPathComponent("store", isDirectory: true)
        let store = SecureFileStore(directoryURL: storeDir)
        let payload = Data("{\"ok\":1}".utf8)
        try store.write(payload, to: "profile.json")

        // 0o775 and 0o777 directories throw .insecureDirectory on read
        #expect(chmod(storeDir.path, 0o775) == 0)
        #expect(throws: SecureFileStoreError.insecureDirectory("\(storeDir.path) has insecure group/other permissions")) {
            _ = try store.read("profile.json")
        }

        #expect(chmod(storeDir.path, 0o777) == 0)
        #expect(throws: SecureFileStoreError.insecureDirectory("\(storeDir.path) has insecure group/other permissions")) {
            _ = try store.read("profile.json")
        }

        // Restored to 0o700 -> reads cleanly
        #expect(chmod(storeDir.path, 0o700) == 0)
        #expect(try store.read("profile.json") == payload)

        // Write repairs 0o750 back to 0o700
        #expect(chmod(storeDir.path, 0o750) == 0)
        let updated = Data("{\"ok\":2}".utf8)
        try store.write(updated, to: "profile.json")
        var dirSt = stat()
        #expect(lstat(storeDir.path, &dirSt) == 0)
        #expect((dirSt.st_mode & 0o777) == 0o700)
        #expect(try store.read("profile.json") == updated)
    }
}
