import Foundation

public enum SwitcherError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct Route: Codable, Equatable {
    public var lines: [String]
    public init(lines: [String] = []) { self.lines = lines }
}

public enum ConfigEditor {
    static let managed: Set<String> = ["model", "model_provider", "openai_base_url", "model_reasoning_effort", "service_tier", "review_model", "model_context_window", "model_auto_compact_token_limit", "model_catalog_json", "forced_login_method"]

    // A deliberately conservative root-scalar editor, not a general TOML parser.
    // Unsupported syntax fails before writing. All shared table text is retained.
    static func split(_ text: String) throws -> (kept: String, route: Route, values: [String: String]) {
        var kept = "", route: [String] = [], values: [String: String] = [:]
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
            let original = String(raw)
            let line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { inTable = true }
            // An overridden built-in provider would defeat the shared-provider contract.
            if line.range(of: #"^\[\s*model_providers\s*\.\s*["']?openai["']?\s*[.\]]"#, options: .regularExpression) != nil {
                throw SwitcherError.message("检测到 openai provider 自定义表。请先恢复内置 provider；未修改配置。")
            }
            if !inTable && !line.isEmpty && !line.hasPrefix("#") {
                guard !line.contains("\"\"\""), !line.contains("'''"),
                      let equal = line.firstIndex(of: "=") else {
                    throw SwitcherError.message("配置包含暂不支持的多行根项；未修改配置。")
                }
                let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
                guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                    throw SwitcherError.message("配置根项使用了带引号或点分键，暂不支持安全编辑。")
                }
                let value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
                // Only complete, one-line root values are accepted. In particular a
                // multiline array must not make a following line look like a table.
                guard value.range(of: #"^(?:"(?:[^"\\]|\\.)*"|'[^']*'|true|false|[+-]?[0-9][0-9_.]*|\[[^\[\]"']*\])\s*(?:#.*)?$"#, options: .regularExpression) != nil else {
                    throw SwitcherError.message("配置根项包含复杂值，暂不支持安全编辑；未修改任何文件。")
                }
                guard values[key] == nil else { throw SwitcherError.message("配置根项重复；请先修复 config.toml。") }
                values[key] = value
                if key == "profile" || key == "forced_login_method" || key == "forced_chatgpt_workspace_id" || key == "chatgpt_base_url" {
                    throw SwitcherError.message("当前配置含 profile 或账号限制/登录地址覆盖，不能安全切换。")
                }
                if managed.contains(key) { route.append(original); continue }
                if key == "cli_auth_credentials_store" { continue }
            }
            kept += original + "\n"
        }
        if let provider = values["model_provider"], try scalar(provider) != "openai" {
            throw SwitcherError.message("仅支持内置 openai provider。请通过切换器添加 Responses API。")
        }
        return (kept, Route(lines: route), values)
    }

    static func scalar(_ value: String) throws -> String {
        // Parse simple quoted TOML strings without accidentally interpreting # in URLs.
        if value.hasPrefix("'") {
            guard let end = value.dropFirst().firstIndex(of: "'") else { throw SwitcherError.message("配置字符串无效。") }
            return String(value[value.index(after: value.startIndex)..<end])
        }
        var escaped = false
        if value.hasPrefix("\"") {
            for index in value.indices.dropFirst() {
                let c = value[index]
                if c == "\"" && !escaped {
                    let quoted = String(value[...index])
                    guard let data = quoted.data(using: .utf8), let result = try? JSONDecoder().decode(String.self, from: data) else { break }
                    return result
                }
                escaped = c == "\\" && !escaped
            }
        }
        throw SwitcherError.message("路由设置必须是普通引号字符串。")
    }

    public static func capture(_ text: String) throws -> Route { try split(text).route }
    public static func endpoint(_ route: Route) throws -> String? {
        let values = try split(route.lines.joined(separator: "\n")).values
        return try values["openai_base_url"].map(scalar)
    }
    public static func model(_ route: Route) throws -> String {
        let values = try split(route.lines.joined(separator: "\n")).values
        return try values["model"].map(scalar) ?? ""
    }
    public static func assertFileImport(_ text: String) throws {
        if let store = try split(text).values["cli_auth_credentials_store"], try scalar(store) != "file" {
            throw SwitcherError.message("当前使用 Keychain/auto 登录。请先在工具中添加登录，或明确改用 file 登录；不会导入可能过期的 auth.json。")
        }
    }

    public static func applying(_ route: Route, to text: String) throws -> String {
        let old = try split(text)
        let incoming = try split(route.lines.joined(separator: "\n"))
        guard incoming.values.keys.allSatisfy({ managed.contains($0) }) else {
            throw SwitcherError.message("账号路由包含非路由配置。")
        }
        var lines = incoming.route.lines
        if incoming.values["model_provider"] == nil { lines.append("model_provider = \"openai\"") }
        lines.append("cli_auth_credentials_store = \"file\"")
        return lines.joined(separator: "\n") + "\n" + old.kept
    }

    public static func api(baseURL: String, model: String) throws -> Route {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: url), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              url.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !url.contains("\""), !url.contains("\\"), !url.contains("'"),
              model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#, options: .regularExpression) != nil else {
            throw SwitcherError.message("请填写 HTTPS 基础地址和有效模型名。地址不能含账号、查询参数或片段；仅本机允许 HTTP。")
        }
        let clean = url.hasSuffix("/") ? String(url.dropLast()) : url
        return Route(lines: ["model_provider = \"openai\"", "openai_base_url = \"\(clean)\"", "model = \"\(model)\""])
    }
}
