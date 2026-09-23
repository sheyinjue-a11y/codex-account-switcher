import XCTest
@testable import SwitcherCore

final class ConfigTests: XCTestCase {
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
