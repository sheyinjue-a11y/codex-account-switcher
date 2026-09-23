import XCTest
import CryptoKit
import Darwin
@testable import SwitcherCore

final class EngineTests: XCTestCase {
    var root: URL!, home: URL!, vault: Vault!, engine: SwitcherEngine!
    let key = SymmetricKey(size: .bits256)
    override func setUpWithError() throws {
        // Resolve /var -> /private/var before testing strict path checks.
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw SwitcherError.message("Test temp directory unavailable") }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("用户/.codex")
        try PrivateFiles.directory(home)
        vault = Vault(root: root.appendingPathComponent("vault"), keyProvider: { self.key })
        engine = SwitcherEngine(home: home, vault: vault, quiescent: {})
    }
    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func auth(_ account: String, token: String = "FAKE_TEST_ONLY") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["account_id": account, "access_token": token, "refresh_token": "FAKE_REFRESH", "id_token": "FAKE_ID"]])
    }
    func seed() throws -> (UUID, UUID) {
        try PrivateFiles.write(auth("one"), to: home.appendingPathComponent("auth.json"))
        try PrivateFiles.write(Data("model = \"old\"\n# shared\n[features]\nplugins = true\n".utf8), to: home.appendingPathComponent("config.toml"))
        try engine.importCurrent(name: "个人")
        try engine.addChatGPT(name: "工作", auth: auth("two"))
        let profiles = try engine.status().profiles
        return (profiles[0].id, profiles[1].id)
    }
    func testHistoryAndAllUnmanagedFilesRemainByteIdentical() throws {
        let ids = try seed()
        let names = ["sessions/rollout.jsonl", "state_5.sqlite", ".codex-global-state.json", "skills/custom/SKILL.md", "plugins/cache.bin", "memories/note.md", "session_index.jsonl", "projects/work/file.txt"]
        var contents: [String: Data] = [:]
        for name in names {
            let file = home.appendingPathComponent(name)
            try PrivateFiles.directory(file.deletingLastPathComponent())
            let bytes = Data(("SENTINEL " + name).utf8)
            try PrivateFiles.write(bytes, to: file); contents[name] = bytes
        }
        try engine.activate(ids.1)
        try engine.saveAPI(name: "API", baseURL: "https://example.com/v1", model: "test-model", key: "FAKE_LOCAL_KEY")
        try engine.activate(engine.status().profiles.last!.id)
        try engine.activate(ids.0)
        for (name, bytes) in contents { XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent(name)), bytes) }
        let config = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("# shared\n[features]\nplugins = true\n"))
        XCTAssertFalse(config.contains("example.com"))
    }
    func testRefreshedCredentialsAreSavedBeforeSwitching() throws {
        let ids = try seed(), refreshed = try auth("one", token: "NEW_FAKE_REFRESHED")
        try PrivateFiles.write(refreshed, to: home.appendingPathComponent("auth.json"))
        try engine.activate(ids.1); try engine.activate(ids.0)
        XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent("auth.json")), refreshed)
    }
    func testKnownIdentityDriftRealignsAndUnknownDriftRefuses() throws {
        let ids = try seed()
        try PrivateFiles.write(auth("two"), to: home.appendingPathComponent("auth.json"))
        try engine.activate(ids.0)
        let unknown = try auth("unknown")
        try PrivateFiles.write(unknown, to: home.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try engine.activate(ids.1))
        XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent("auth.json")), unknown)
    }
    func testRollbackAtEachWriteBoundary() throws {
        let ids = try seed()
        let authBefore = try PrivateFiles.read(home.appendingPathComponent("auth.json")), configBefore = try PrivateFiles.read(home.appendingPathComponent("config.toml"))
        for point in ["config", "auth", "registry"] {
            let failing = SwitcherEngine(home: home, vault: vault, quiescent: {}, checkpoint: { if $0 == point { throw SwitcherError.message("test failure") } })
            XCTAssertThrowsError(try failing.activate(ids.1))
            XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent("auth.json")), authBefore)
            XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent("config.toml")), configBefore)
            XCTAssertEqual(try engine.status().activeID, ids.0)
            XCTAssertFalse(try engine.hasPending())
        }
    }
    func testInterruptedRecoveryAndExternalEditProtection() throws {
        let ids = try seed(), before = try engine.status()
        let oldAuth = try PrivateFiles.read(home.appendingPathComponent("auth.json")), oldConfig = try PrivateFiles.read(home.appendingPathComponent("config.toml"))
        let newAuth = try auth("two"), newConfig = Data("model_provider = \"openai\"\n".utf8)
        try vault.save(Journal(previous: before, oldAuth: oldAuth, oldConfig: oldConfig, newAuth: newAuth, newConfig: newConfig), name: "pending.enc")
        try PrivateFiles.write(newConfig, to: home.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try engine.activate(ids.1))
        try engine.recover()
        XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent("config.toml")), oldConfig)
        try vault.save(Journal(previous: before, oldAuth: oldAuth, oldConfig: oldConfig, newAuth: newAuth, newConfig: newConfig), name: "pending.enc")
        let external = Data("# external change\n".utf8)
        try PrivateFiles.write(external, to: home.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try engine.recover())
        XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent("config.toml")), external)
        XCTAssertTrue(try engine.hasPending())
    }
    func testRunningProcessStopsSwitchBeforeWrites() throws {
        let ids = try seed(), before = try PrivateFiles.read(home.appendingPathComponent("auth.json"))
        let blocked = SwitcherEngine(home: home, vault: vault, quiescent: { throw SwitcherError.message("busy") })
        XCTAssertThrowsError(try blocked.activate(ids.1))
        XCTAssertEqual(try PrivateFiles.read(home.appendingPathComponent("auth.json")), before)
    }
    func testDuplicatesAndDeletionGuards() throws {
        let ids = try seed()
        XCTAssertThrowsError(try engine.addChatGPT(name: "duplicate", auth: auth("one")))
        XCTAssertThrowsError(try engine.delete(ids.0))
        try engine.delete(ids.1)
        XCTAssertThrowsError(try engine.delete(ids.0))
    }
    func testAPIEditKeepsBlankKeyAndProtectsActive() throws {
        let ids = try seed()
        try engine.saveAPI(name: "API", baseURL: "https://example.com/v1", model: "test", key: "FAKE_KEY")
        let api = try engine.status().profiles.last!
        try engine.saveAPI(name: "API 2", baseURL: "https://example.org/v1", model: "test2", key: "", replacing: api.id)
        XCTAssertEqual(try engine.status().profiles.last!.auth, api.auth)
        try engine.activate(api.id)
        XCTAssertThrowsError(try engine.saveAPI(name: "API", baseURL: "https://example.org/v1", model: "test", key: "", replacing: api.id))
        try engine.activate(ids.0)
    }
    func testVaultEncryptionTamperAndPermissions() throws {
        _ = try seed()
        let path = vault.root.appendingPathComponent("profiles.enc")
        var bytes = try PrivateFiles.read(path)!
        XCTAssertNil(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(bytes.range(of: Data("FAKE_TEST_ONLY".utf8)) != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        bytes[bytes.count - 1] ^= 1
        try PrivateFiles.write(bytes, to: path)
        XCTAssertThrowsError(try engine.status())
    }
    func testLockAndSymlinkGuards() throws {
        _ = try seed()
        let lock = try OperationLock(directory: vault.root)
        try withExtendedLifetime(lock) { XCTAssertThrowsError(try engine.status()) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        XCTAssertThrowsError(try PrivateFiles.read(link.appendingPathComponent("auth.json")))
        let hardlink = home.appendingPathComponent("hard.json")
        try FileManager.default.linkItem(at: home.appendingPathComponent("auth.json"), to: hardlink)
        XCTAssertThrowsError(try PrivateFiles.read(hardlink))
    }
    func testSpecialFilesAreRejectedWithoutBlocking() throws {
        let fifo = root.appendingPathComponent("named-pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try PrivateFiles.read(fifo))
    }
    func testFirstProfileCanActivateWithoutExistingAuth() throws {
        try engine.addChatGPT(name: "first", auth: auth("one"))
        let id = try engine.status().profiles[0].id
        try engine.activate(id)
        XCTAssertEqual(try engine.status().activeID, id)
    }
    func testKeyringTakeoverRequiresExplicitConsentAndKeepsBackup() throws {
        let stale = try auth("old")
        try PrivateFiles.write(stale, to: home.appendingPathComponent("auth.json"))
        let config = Data("cli_auth_credentials_store = \"auto\"\n[features]\nplugins = true\n".utf8)
        try PrivateFiles.write(config, to: home.appendingPathComponent("config.toml"))
        try engine.addChatGPT(name: "new", auth: auth("new"))
        let id = try engine.status().profiles[0].id
        XCTAssertThrowsError(try engine.activate(id))
        try engine.activate(id, replacingUnmanagedLogin: true)
        let backup = try vault.load(Journal.self, name: "first-login-backup.enc")
        XCTAssertEqual(backup?.oldAuth, stale)
        XCTAssertEqual(backup?.oldConfig, config)
        XCTAssertEqual(try engine.status().activeID, id)
    }
}
