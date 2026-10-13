import XCTest
@testable import SwitcherCore

final class DesktopRuntimePolicyTests: XCTestCase {
    func testCurrentImportAcceptsFileOrDefaultStoreIncludingUTF8BOM() {
        XCTAssertTrue(DesktopRuntimePolicy.canImportCurrent(authExists: true, configuration: nil))
        for text in ["", "model = \"test\"\n", "cli_auth_credentials_store = \"file\"\n",
                     "\u{FEFF}cli_auth_credentials_store = \"file\"\n"] {
            XCTAssertTrue(DesktopRuntimePolicy.canImportCurrent(authExists: true, configuration: Data(text.utf8)))
        }
    }

    func testCurrentImportRejectsKeychainModesEvenWhenAuthFileExists() {
        for store in ["auto", "keyring"] {
            let configuration = Data("cli_auth_credentials_store = \"\(store)\"\n".utf8)
            XCTAssertFalse(DesktopRuntimePolicy.canImportCurrent(authExists: true, configuration: configuration), store)
        }
    }

    func testCurrentImportRejectsMissingAuthOrInvalidUTF8() {
        XCTAssertFalse(DesktopRuntimePolicy.canImportCurrent(authExists: false, configuration: nil))
        XCTAssertFalse(DesktopRuntimePolicy.canImportCurrent(authExists: false, configuration: Data("cli_auth_credentials_store = \"file\"\n".utf8)))
        XCTAssertFalse(DesktopRuntimePolicy.canImportCurrent(authExists: true, configuration: Data([0xff, 0xfe, 0x00])))
    }

    func testExplicitLoginComponentOverridesBundledComponent() {
        let candidates = DesktopRuntimePolicy.loginCandidates(
            selected: "/Users/test/Custom Tools/codex", desktop: URL(fileURLWithPath: "/Applications/Codex.app"),
            userHome: "/Users/test")
        XCTAssertEqual(candidates.first, "/Users/test/Custom Tools/codex")
        XCTAssertTrue(candidates.contains("/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/codex"))
    }

    func testLoginIsolationRemovesSharedDatabaseAndServerOverrides() {
        let inherited = [
            "CODEX_HOME": "/Users/test/.codex", "CODEX_SQLITE_HOME": "/Users/test/shared-db",
            "CODEX_APP_SERVER_OPENAI_BASE_URL": "https://api.example.test/v1",
            "CODEX_APP_SERVER_CHATGPT_BASE_URL": "https://chat.example.test",
            "CODEX_ELECTRON_USER_DATA_PATH": "/Users/test/shared-desktop",
            "OPENAI_API_KEY": "FAKE_KEY", "CODEX_API_KEY": "FAKE_OTHER_KEY",
            "CODEX_ACCESS_TOKEN": "FAKE_TOKEN", "CODEX_AUTH_JSON": "FAKE_AUTH",
            "OPENAI_BASE_URL": "https://other.example.test/v1", "CODEX_PROFILE": "work",
            "PATH": "/custom/bin", "LANG": "zh_CN.UTF-8"
        ]
        let clean = DesktopRuntimePolicy.loginEnvironment(inherited, home: URL(fileURLWithPath: "/private/tmp/login-fixture"))
        XCTAssertEqual(clean["CODEX_HOME"], "/private/tmp/login-fixture")
        for name in inherited.keys where !["CODEX_HOME", "PATH", "LANG"].contains(name) {
            XCTAssertNil(clean[name], name)
        }
        XCTAssertEqual(clean["LANG"], "zh_CN.UTF-8")
        XCTAssertTrue(clean["PATH"]?.hasSuffix(":/custom/bin") == true)
        XCTAssertEqual(inherited["CODEX_SQLITE_HOME"], "/Users/test/shared-db")
    }

    @MainActor func testWaitsForBundledHelperAfterDesktopCloses() async throws {
        var clock = 0.0
        var polls = 0
        let snapshots = [
            " 100 1 /Applications/My Codex.app/Contents/Resources/codex\n",
            " 101 1 /Applications/My Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper\n",
            " 200 1 /opt/homebrew/bin/codex\n"
        ]
        try await DesktopRuntimePolicy.waitForDesktopExit(
            app: URL(fileURLWithPath: "/Applications/My Codex.app"), processIDs: [99],
            initialSnapshot: "100 99 /Applications/My Codex.app/Contents/Resources/codex\n101 100 /Applications/My Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper\n",
            isTerminated: { true },
            processSnapshot: { let result = snapshots[polls]; polls += 1; return result },
            timeout: 10, now: { clock }, sleep: { clock += 1 })
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(clock, 2)
    }

    @MainActor func testDoesNotWaitForIndependentCLIOrAnotherApp() async throws {
        var sleeps = 0
        try await DesktopRuntimePolicy.waitForDesktopExit(
            app: URL(fileURLWithPath: "/Applications/Codex.app"), processIDs: [99], initialSnapshot: "",
            isTerminated: { true },
            processSnapshot: { "200 1 /opt/homebrew/bin/codex\n201 1 /Applications/Codex.app.old/Contents/Resources/codex\n202 1 /Applications/Codex.app/Contents/Resources/codex\n" },
            now: { 0 }, sleep: { sleeps += 1 })
        XCTAssertEqual(sleeps, 0)
    }

    @MainActor func testKeepsWaitingWhileMainApplicationIsRunning() async throws {
        var clock = 0.0
        var snapshots = 0
        try await DesktopRuntimePolicy.waitForDesktopExit(
            app: URL(fileURLWithPath: "/Applications/Codex.app"), processIDs: [99], initialSnapshot: "",
            isTerminated: { clock >= 2 },
            processSnapshot: { snapshots += 1; return "" },
            now: { clock }, sleep: { clock += 1 })
        XCTAssertEqual(clock, 2)
        XCTAssertEqual(snapshots, 3)
    }

    @MainActor func testStuckHelperTimesOutWithoutTerminatingIt() async {
        var clock = 0.0
        do {
            try await DesktopRuntimePolicy.waitForDesktopExit(
                app: URL(fileURLWithPath: "/Applications/Codex.app"), processIDs: [99],
                initialSnapshot: "100 99 /Applications/Codex.app/Contents/Resources/codex\n", isTerminated: { true },
                processSnapshot: { "100 1 /Applications/Codex.app/Contents/Resources/codex\n" },
                timeout: 2, now: { clock }, sleep: { clock += 1 })
            XCTFail("A still-running bundled helper must block switching")
        } catch {
            XCTAssertEqual(clock, 2)
            XCTAssertTrue(error.localizedDescription.contains("未正常退出"))
        }
    }

    @MainActor func testProcessInspectionFailureDoesNotReportDesktopStopped() async {
        do {
            try await DesktopRuntimePolicy.waitForDesktopExit(
                app: URL(fileURLWithPath: "/Applications/Codex.app"), processIDs: [99], initialSnapshot: "", isTerminated: { true },
                processSnapshot: { throw SwitcherError.message("fixture process inspection failed") },
                now: { 0 }, sleep: { XCTFail("Inspection errors must not be retried as successful shutdown") })
            XCTFail("Process inspection failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture process inspection failed"))
        }
    }
}
