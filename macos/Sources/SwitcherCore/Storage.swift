import Foundation
import CryptoKit
import Security
import Darwin

public enum PrivateFiles {
    public static func check(_ url: URL) throws {
        // NSURL standardization may shorten /private/var back to the /var
        // symlink on macOS. Inspect the supplied physical path, not that alias.
        let path = url.path
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for part in path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            var info = stat()
            if lstat(cursor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw SwitcherError.message("检测到符号链接，停止写入。请使用真实本地目录。") }
                if (info.st_mode & S_IFMT) == S_IFREG {
                    guard info.st_nlink == 1, info.st_uid == getuid() else { throw SwitcherError.message("文件有硬链接或不属于当前用户。") }
                }
            } else if errno != ENOENT { throw SwitcherError.message("无法检查本地文件权限。") }
        }
    }
    public static func directory(_ url: URL) throws {
        try check(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              chmod(url.path, 0o700) == 0 else { throw SwitcherError.message("无法保护本地目录权限。") }
    }
    public static func read(_ url: URL) throws -> Data? {
        try check(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SwitcherError.message("无法读取本地文件。")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_size <= 16_777_216 else { throw SwitcherError.message("本地文件类型、所有权或大小异常。") }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    public static func write(_ data: Data, to url: URL) throws {
        try check(url)
        let parent = url.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".switcher-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SwitcherError.message("无法创建安全临时文件。") }
        defer { close(fd); unlink(temp.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw SwitcherError.message("文件写入未能同步。") }
        try check(url)
        guard rename(temp.path, url.path) == 0 else { throw SwitcherError.message("原子替换文件失败。") }
        syncDirectory(parent)
    }
    public static func remove(_ url: URL) throws {
        try check(url)
        guard unlink(url.path) == 0 || errno == ENOENT else { throw SwitcherError.message("无法移除已完成的临时记录。") }
        syncDirectory(url.deletingLastPathComponent())
    }
    static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
}

public final class OperationLock {
    private var fd: Int32 = -1
    public init(directory: URL) throws {
        try PrivateFiles.directory(directory)
        let url = directory.appendingPathComponent("operation.lock")
        try PrivateFiles.check(url)
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw SwitcherError.message("无法建立账号库锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1
            throw SwitcherError.message("另一个切换器正在操作，请稍后重试。")
        }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}

public final class Vault {
    public let root: URL
    private let keyProvider: () throws -> SymmetricKey
    public init(root: URL, keyProvider: @escaping () throws -> SymmetricKey) {
        self.root = root; self.keyProvider = keyProvider
    }
    public func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        guard let bytes = try PrivateFiles.read(root.appendingPathComponent(name)) else { return nil }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyProvider(), authenticating: Data(name.utf8))
            return try JSONDecoder().decode(type, from: plain)
        } catch { throw SwitcherError.message("账号库无法解密或已损坏。请检查钥匙串权限；不要删除原文件。") }
    }
    public func save<T: Encodable>(_ value: T, name: String) throws {
        let plain = try JSONEncoder().encode(value)
        guard plain.count < 12_000_000 else { throw SwitcherError.message("账号库过大，未保存。") }
        guard let encrypted = try AES.GCM.seal(plain, using: keyProvider(), authenticating: Data(name.utf8)).combined else {
            throw SwitcherError.message("无法加密账号库。")
        }
        try PrivateFiles.write(encrypted, to: root.appendingPathComponent(name))
    }
    public func remove(_ name: String) throws { try PrivateFiles.remove(root.appendingPathComponent(name)) }
}

public enum KeychainKey {
    public static func loadOrCreate(allowCreate: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.sheyinjue-a11y.codex-account-switcher",
            kSecAttrAccount as String: "vault-key-v1", kSecAttrSynchronizable as String: false]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, allowCreate else {
            throw SwitcherError.message("无法读取钥匙串密钥（\(status)）。请解锁登录钥匙串并允许此工具访问；不会重置账号库。")
        }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw SwitcherError.message("无法生成安全密钥。") }
        var create = query
        create[kSecValueData as String] = bytes
        create[kSecAttrLabel as String] = "Codex Account Switcher local vault"
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(create as CFDictionary, nil)
        if added == errSecDuplicateItem { return try loadOrCreate(allowCreate: false) }
        guard added == errSecSuccess else { throw SwitcherError.message("无法保存钥匙串密钥（\(added)）。") }
        return SymmetricKey(data: bytes)
    }
}
