import XCTest
import Foundation
import Darwin
@testable import SwitcherCore

final class AstraWarmupTests: XCTestCase {
    private var sandbox: URL!
    private var home: URL!
    private var root: URL!
    private let key = "FAKE_NATIVE_TEST_KEY"
    private let endpoint = "https://api.example.test/v1"
    private let block = #"{"decision":"block","reason":"Astra warmup failed; original message was not sent. Retry or disable warmup."}"#

    override func setUpWithError() throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw SwitcherError.message("Cannot resolve test temporary directory")
        }
        defer { free(physical) }
        sandbox = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("astra-native-tests-\(UUID().uuidString)")
        home = sandbox.appendingPathComponent("home")
        root = sandbox.appendingPathComponent("vault")
        try PrivateFiles.directory(home)
        try PrivateFiles.directory(root)
        try PrivateFiles.write(Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_NATIVE_TEST_KEY"}"#.utf8), to: home.appendingPathComponent("auth.json"))
        try PrivateFiles.write(Data("model = \"gpt-6-astra\"\nmodel_provider = \"openai\"\nopenai_base_url = \"\(endpoint)\"\ncli_auth_credentials_store = \"file\"\n".utf8), to: home.appendingPathComponent("config.toml"))
    }

    override func tearDownWithError() throws {
        if let sandbox { try FileManager.default.removeItem(at: sandbox) }
    }

    private func enable() throws {
        try AstraWarmup.setEnabled(true, home: home, root: root,
                                   executable: sandbox.appendingPathComponent("Codex Account Switcher.app/Contents/MacOS/CodexAccountSwitcher"),
                                   consent: true)
    }

    private func event(_ session: String = "session-one", model: String = "gpt-6-astra") -> Data {
        Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)","model":"\#(model)","prompt":"PRIVATE_ORIGINAL_SENTINEL"}"#.utf8)
    }

    private func markerCount() throws -> Int {
        let directory = root.appendingPathComponent("astra-warmup-sessions")
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        }.count) ?? 0
    }

    func testMarkerCountDistinguishesMissingDirectoryFromReadFailure() throws {
        XCTAssertEqual(try markerCount(), 0)
        try PrivateFiles.write(Data("not a directory".utf8), to: root.appendingPathComponent("astra-warmup-sessions"))
        XCTAssertThrowsError(try markerCount())
    }

    func testAmbiguousRoutesBlockBeforeTransportAndInstallationPreservesConsentAndHooks() throws {
        try enable()
        let configURL = home.appendingPathComponent("config.toml")
        let config = String(decoding: try XCTUnwrap(PrivateFiles.read(configURL)), as: UTF8.self)
        let hooksURL = home.appendingPathComponent("hooks.json")
        let consentURL = root.appendingPathComponent("astra-warmup.json")
        let hooks = try PrivateFiles.read(hooksURL)
        let consent = try PrivateFiles.read(consentURL)
        var invalid = ["profile = \"work\"\n" + config,
                       "cli_auth_credentials_store = 'file'\n\"openai_base_url\" = 'https://actual.example.test/v1'\n",
                       "cli_auth_credentials_store = 'file'\n'openai_base_url' = 'https://actual.example.test/v1'\n",
                       config + "[model_providers]\nopenai = { base_url = 'https://actual.example.test/v1' }\n"]
        for provider in ["model_providers", "\"model_providers\"", "'model_providers'", #""\u006dodel_providers""#] {
            for builtin in ["openai", "\"openai\"", "'openai'", #""\u006fpenai""#] {
                invalid.append(config + "[ \(provider) . \(builtin) ]\nbase_url = 'https://actual.example.test/v1'\n")
            }
        }
        let transport: AstraWarmup.Transport = { _ in
            XCTFail("Ambiguous route must be rejected before transport")
            return (200, "application/json", Data(#"{"status":"completed"}"#.utf8))
        }
        for text in invalid {
            try PrivateFiles.write(Data(text.utf8), to: configURL)
            XCTAssertThrowsError(try enable(), text)
            XCTAssertEqual(try PrivateFiles.read(hooksURL), hooks)
            XCTAssertEqual(try PrivateFiles.read(consentURL), consent)
            XCTAssertEqual(String(decoding: try XCTUnwrap(AstraWarmup.run(event: event(), home: home, root: root, transport: transport)), as: UTF8.self), block)
            XCTAssertEqual(try markerCount(), 0)
        }
    }

    func testUnrelatedConfigTablesPreservedByWarmupInstallation() throws {
        let configURL = home.appendingPathComponent("config.toml")
        var config = try XCTUnwrap(PrivateFiles.read(configURL))
        config.append(Data("[mcp_servers.demo]\ncommand = 'local-server'\n[projects.\"/Users/test/example workspace\"]\ntrust_level = 'trusted'\n[model_providers.other]\nbase_url = 'https://other.example.test/v1'\n".utf8))
        try PrivateFiles.write(config, to: configURL)
        try enable()
        XCTAssertTrue(try AstraWarmup.isEnabled(home: home, root: root))
        XCTAssertEqual(try PrivateFiles.read(configURL), config)
    }

    func testSuccessfulWarmupSendsOnlyFixedSolRequestAndRunsOncePerSession() throws {
        try enable()
        var requests: [URLRequest] = []
        let transport: AstraWarmup.Transport = { request in
            requests.append(request)
            return (200, "text/event-stream", Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8))
        }
        XCTAssertNil(AstraWarmup.run(event: event(), home: home, root: root, transport: transport))
        XCTAssertNil(AstraWarmup.run(event: event(), home: home, root: root, transport: transport))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, endpoint + "/responses")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let body = try XCTUnwrap(requests.first?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(object["input"] as? String, "Reply only OK.")
        XCTAssertEqual((object["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual((object["tools"] as? [Any])?.count, 0)
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertEqual(object["max_output_tokens"] as? Int, 256)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("PRIVATE_ORIGINAL_SENTINEL"))
        XCTAssertEqual(try markerCount(), 1)
    }

    func testErrorsNeverMarkCompletionAndRetryRemainsPossible() throws {
        try enable()
        var attempts = 0
        let failed: AstraWarmup.Transport = { _ in
            attempts += 1
            return (200, "text/event-stream", Data("event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"SECRET_BODY\"}}}\n\n".utf8))
        }
        XCTAssertEqual(String(decoding: try XCTUnwrap(AstraWarmup.run(event: event(), home: home, root: root, transport: failed)), as: UTF8.self), block)
        XCTAssertEqual(String(decoding: try XCTUnwrap(AstraWarmup.run(event: event(), home: home, root: root, transport: failed)), as: UTF8.self), block)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try markerCount(), 0)
    }

    func testMalformedInputBlocksBeforeReadingAuth() throws {
        try PrivateFiles.remove(home.appendingPathComponent("auth.json"))
        XCTAssertEqual(String(decoding: try XCTUnwrap(AstraWarmup.run(event: Data("{broken".utf8), home: home, root: root)), as: UTF8.self), block)
        XCTAssertEqual(try markerCount(), 0)
    }

    func testIrrelevantEventsDoNotCallTransport() throws {
        try enable()
        let unexpected: AstraWarmup.Transport = { _ in XCTFail("Unexpected network request"); return (500, "", Data()) }
        XCTAssertNil(AstraWarmup.run(event: event(model: "gpt-5.6-sol"), home: home, root: root, transport: unexpected))
        XCTAssertNil(AstraWarmup.run(event: Data(#"{"hook_event_name":"Other","session_id":"s","model":"gpt-6-astra"}"#.utf8), home: home, root: root, transport: unexpected))
        XCTAssertEqual(try markerCount(), 0)
    }

    func testDifferentAppServerRouteOverrideBlocksBeforeNetwork() throws {
        try enable()
        let name = "CODEX_APP_SERVER_OPENAI_BASE_URL"
        let previous = getenv(name).map { String(cString: $0) }
        defer { if let previous { setenv(name, previous, 1) } else { unsetenv(name) } }
        setenv(name, "https://elsewhere.example.test/v1", 1)
        var requests = 0
        let transport: AstraWarmup.Transport = { _ in
            requests += 1
            return (200, "application/json", Data(#"{"status":"completed"}"#.utf8))
        }
        XCTAssertEqual(String(decoding: try XCTUnwrap(AstraWarmup.run(event: event(), home: home, root: root, transport: transport)), as: UTF8.self), block)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try markerCount(), 0)
    }

    func testMatchingAppServerRouteOverrideAllowsWarmup() throws {
        try enable()
        let name = "CODEX_APP_SERVER_OPENAI_BASE_URL"
        let previous = getenv(name).map { String(cString: $0) }
        defer { if let previous { setenv(name, previous, 1) } else { unsetenv(name) } }
        setenv(name, endpoint + "/", 1)
        let transport: AstraWarmup.Transport = { _ in
            (200, "application/json", Data(#"{"status":"completed"}"#.utf8))
        }
        XCTAssertNil(AstraWarmup.run(event: event(), home: home, root: root, transport: transport))
        XCTAssertEqual(try markerCount(), 1)
    }

    func testEnablePreservesUnrelatedEmptyHookGroupAndDisableRemovesOnlyOwnedHandler() throws {
        let hooks = #"{"hooks":{"UserPromptSubmit":[{"matcher":"keep-empty","hooks":[],"unknown":42},{"matcher":"keep-other","hooks":[{"type":"command","command":"/bin/true"}]}],"OtherEvent":[{"hooks":[]}]}}"#
        try PrivateFiles.write(Data(hooks.utf8), to: home.appendingPathComponent("hooks.json"))
        try enable()
        try AstraWarmup.setEnabled(false, home: home, root: root,
                                   executable: sandbox.appendingPathComponent("Codex Account Switcher.app/Contents/MacOS/CodexAccountSwitcher"), consent: false)
        let data = try XCTUnwrap(PrivateFiles.read(home.appendingPathComponent("hooks.json")))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allHooks = try XCTUnwrap(parsed["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(allHooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["matcher"] as? String, "keep-empty")
        XCTAssertEqual(groups[0]["unknown"] as? Int, 42)
        XCTAssertEqual((groups[0]["hooks"] as? [Any])?.count, 0)
        XCTAssertEqual((groups[1]["hooks"] as? [Any])?.count, 1)
        XCTAssertNotNil(allHooks["OtherEvent"])
        XCTAssertFalse(try AstraWarmup.isEnabled(home: home, root: root))
    }

    func testInstallerRejectsShellExpansionCharactersInExecutablePath() throws {
        for component in ["$USER", "`id`", #"back\slash"#] {
            let executable = sandbox.appendingPathComponent(component).appendingPathComponent("CodexAccountSwitcher")
            XCTAssertThrowsError(try AstraWarmup.setEnabled(true, home: home, root: root,
                                                             executable: executable, consent: true), component)
        }
        XCTAssertNil(try PrivateFiles.read(home.appendingPathComponent("hooks.json")))
        XCTAssertNil(try PrivateFiles.read(root.appendingPathComponent("astra-warmup.json")))
    }

    func testEditorRejectsShellExpansionInMovedOwnedHandler() throws {
        try enable()
        let hooksURL = home.appendingPathComponent("hooks.json")
        let data = try XCTUnwrap(PrivateFiles.read(hooksURL))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        var handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        handlers[0]["command"] = #""/tmp/$USER/CodexAccountSwitcher" --astra-warmup"#
        groups[0]["hooks"] = handlers
        hooks["UserPromptSubmit"] = groups
        document["hooks"] = hooks
        let modified = try JSONSerialization.data(withJSONObject: document)
        try PrivateFiles.write(modified, to: hooksURL)
        XCTAssertThrowsError(try AstraWarmup.setEnabled(false, home: home, root: root,
                                                         executable: sandbox.appendingPathComponent("CodexAccountSwitcher"), consent: false))
        XCTAssertEqual(try PrivateFiles.read(hooksURL), modified)
    }
}
