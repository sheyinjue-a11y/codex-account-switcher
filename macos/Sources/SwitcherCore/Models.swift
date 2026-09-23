import Foundation
import CryptoKit

public enum ProfileKind: String, Codable { case chatgpt, responsesAPI }

public struct Credential {
    public let kind: ProfileKind
    public let identity: String
    public init(_ data: Data) throws {
        guard data.count < 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwitcherError.message("登录文件无效或过大。")
        }
        let mode = object["auth_mode"] as? String ?? ""
        let key = object["OPENAI_API_KEY"] as? String ?? ""
        if mode == "chatgpt", key.isEmpty, let tokens = object["tokens"] as? [String: Any],
           let account = tokens["account_id"] as? String, !account.isEmpty,
           let access = tokens["access_token"] as? String, !access.isEmpty,
           let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
           let id = tokens["id_token"] as? String, !id.isEmpty {
            kind = .chatgpt
            identity = Self.hash(Data(("chatgpt:" + account).utf8))
        } else if ["", "apikey", "api_key"].contains(mode), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  object["tokens"] == nil || object["tokens"] is NSNull {
            kind = .responsesAPI
            identity = Self.hash(Data(("api:" + key).utf8))
        } else { throw SwitcherError.message("不支持的登录格式。请使用官方浏览器登录或有效 API Key。") }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func api(_ key: String) throws -> Data {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.count < 16_384,
              key.rangeOfCharacter(from: .controlCharacters) == nil else { throw SwitcherError.message("API Key 为空或含控制字符。") }
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": key])
    }
}

public struct Profile: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var kind: ProfileKind
    public var auth: Data
    public var route: Route
    public init(id: UUID = UUID(), name: String, auth: Data, route: Route) throws {
        self.id = id; self.name = try Self.validName(name)
        self.kind = try Credential(auth).kind; self.auth = auth; self.route = route
        try validate()
    }
    public static func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 60, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SwitcherError.message("名称需为 1–60 个字符，不能含换行或控制字符。")
        }
        return value
    }
    public func validate() throws {
        _ = try Self.validName(name)
        guard try Credential(auth).kind == kind else { throw SwitcherError.message("账号类型不匹配。") }
        _ = try ConfigEditor.applying(route, to: "")
        if kind == .chatgpt, try ConfigEditor.endpoint(route) != nil {
            throw SwitcherError.message("ChatGPT 登录不能发送到自定义 API 地址。")
        }
        if kind == .responsesAPI, let endpoint = try ConfigEditor.endpoint(route) {
            _ = try ConfigEditor.api(baseURL: endpoint, model: try ConfigEditor.model(route))
        }
    }
}

public struct Registry: Codable {
    public var version = 1
    public var profiles: [Profile] = []
    public var activeID: UUID?
    public init() {}
    public func validate() throws {
        guard version == 1, profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count,
              activeID == nil || profiles.contains(where: { $0.id == activeID }) else {
            throw SwitcherError.message("账号库格式无效或版本不支持；请保留原文件。")
        }
        for profile in profiles { try profile.validate() }
    }
}
