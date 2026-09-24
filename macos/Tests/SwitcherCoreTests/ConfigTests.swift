import XCTest
@testable import SwitcherCore

final class ConfigTests: XCTestCase {
    func testCatalogValidationRejectsInvalidListsWithoutInventingModels() throws {
        for text in ["{broken", "{}", "{\"models\":[]}", "{\"models\":{}}",
                     "{\"models\":[{\"slug\":\"hidden\",\"visibility\":\"hide\",\"supported_in_api\":true}]}",
                     "{\"models\":[{\"slug\":\"a\",\"visibility\":\"list\",\"supported_in_api\":true},{\"slug\":\"a\"}]}"] {
            XCTAssertNil(ModelCatalog.validated(Data(text.utf8)), text)
        }
        XCTAssertNil(ModelCatalog.validated(nil))
        let route = try ConfigEditor.api(baseURL: "https://example.test/v1", model: "gpt-6-astra")
        let path = "/Users/test/用户/vault/models.json"
        XCTAssertEqual(try ConfigEditor.catalog(ConfigEditor.withCatalog(route, path: path)), path)
        XCTAssertEqual(try ConfigEditor.withCatalog(ConfigEditor.withCatalog(route, path: path), path: nil), route)
    }
    func testRejectsUnsupportedOrDangerousOverrides() {
        for text in ["model_provider = \"custom\"", "profile = \"work\"", "\"model\" = \"test\"", "notify = [\n\"cmd\"\n]", "model = \"\"\"multi\nline\"\"\"", "[model_providers.openai]\nbase_url = \"https://evil.example\"", "forced_chatgpt_workspace_id = \"workspace\""] {
            XCTAssertThrowsError(try ConfigEditor.applying(Route(), to: text), text)
        }
        XCTAssertThrowsError(try ConfigEditor.assertFileImport("cli_auth_credentials_store = \"keyring\""))
        XCTAssertThrowsError(try ConfigEditor.assertFileImport("cli_auth_credentials_store = \"auto\""))
    }
    func testAPIValidationAndChatGPTLeakGuard() throws {
        for url in ["http://example.com/v1", "https://user:pass@example.com", "https://example.com?q=key", "https://example.com/#token", "https://example.com/\nmodel=bad"] {
            XCTAssertThrowsError(try ConfigEditor.api(baseURL: url, model: "test"))
        }
        XCTAssertNoThrow(try ConfigEditor.api(baseURL: "http://127.0.0.1:4321/v1", model: "test"))
        XCTAssertThrowsError(try ConfigEditor.api(baseURL: "https://example.com", model: "x\"\n"))
        let auth = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["account_id": "a", "id_token": "fake", "access_token": "fake", "refresh_token": "fake"]])
        XCTAssertThrowsError(try Profile(name: "bad", auth: auth, route: ConfigEditor.api(baseURL: "https://example.com", model: "test")))
    }
    func testSwitchChangesRouteButKeepsSharedSettings() throws {
        let shared = "# shared\napproval_policy = \"on-request\"\n[mcp_servers.demo]\ncommand = \"local-server\"\n[projects.\"/Users/test/项目\"]\ntrust_level = \"trusted\"\n"
        let config = "model = \"old-model\"\n" + shared
        let result = try ConfigEditor.applying(Route(lines: ["model = \"new-model\"", "model_provider = \"openai\""]), to: config)
        XCTAssertTrue(result.contains("model = \"new-model\""))
        XCTAssertFalse(result.contains("old-model"))
        XCTAssertTrue(result.contains(shared))
        XCTAssertTrue(result.contains("cli_auth_credentials_store = \"file\""))
    }
}
