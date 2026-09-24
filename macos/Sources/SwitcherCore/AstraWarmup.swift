import Foundation
import CryptoKit
import Darwin

public enum AstraWarmup {
    public typealias Transport = (URLRequest) throws -> (status: Int, contentType: String, data: Data)

    private static let statusMessage = "Codex Account Switcher: Astra warmup"
    private static let blockData = Data(#"{"decision":"block","reason":"Astra warmup failed; original message was not sent. Retry or disable warmup."}"#.utf8)
    private static let consentName = "astra-warmup.json"
    private static let maximumResponse = 131_072

    private struct Account {
        let endpoint: String
        let key: String
        var fingerprint: String { digest(endpoint + "\n" + key) }
    }

    private struct Consent: Codable {
        let version: Int
        var profiles: [String]
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func readAccount(home: URL) throws -> Account? {
        try PrivateFiles.check(home)
        guard let auth = try PrivateFiles.read(home.appendingPathComponent("auth.json")), auth.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: auth) as? [String: Any] else {
            throw SwitcherError.message("A file API login is required for Astra warmup.")
        }
        if object["auth_mode"] as? String == "chatgpt" { return nil }
        let mode = object["auth_mode"] as? String ?? ""
        guard ["", "apikey", "api_key"].contains(mode), object["tokens"] == nil || object["tokens"] is NSNull,
              let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty, key.count < 16_384,
              key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              key.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SwitcherError.message("A file API login is required for Astra warmup.")
        }
        guard let config = try PrivateFiles.read(home.appendingPathComponent("config.toml")), config.count <= 1_048_576,
              let text = String(data: config, encoding: .utf8) else {
            throw SwitcherError.message("A valid Codex route is required for Astra warmup.")
        }
        let values = try ConfigEditor.split(text).values
        if let provider = values["model_provider"], try ConfigEditor.scalar(provider) != "openai" {
            throw SwitcherError.message("Astra warmup requires the built-in OpenAI provider.")
        }
        guard let store = values["cli_auth_credentials_store"], try ConfigEditor.scalar(store) == "file" else {
            throw SwitcherError.message("Astra warmup requires file API credentials.")
        }
        let raw = try values["openai_base_url"].map(ConfigEditor.scalar) ?? "https://api.openai.com/v1"
        guard let parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              (parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))),
              !raw.contains("%"), !raw.contains("\\"), raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = parts.url else {
            throw SwitcherError.message("Astra warmup requires an HTTPS or loopback API address.")
        }
        return Account(endpoint: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), key: key)
    }

    private static func readConsent(root: URL) throws -> Consent {
        guard let data = try PrivateFiles.read(root.appendingPathComponent(consentName)) else {
            return Consent(version: 1, profiles: [])
        }
        guard data.count <= 131_072, let value = try? JSONDecoder().decode(Consent.self, from: data),
              value.version == 1, value.profiles.count <= 1000,
              Set(value.profiles).count == value.profiles.count,
              value.profiles.allSatisfy({ $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else {
            throw SwitcherError.message("Astra warmup settings are invalid.")
        }
        return value
    }

    public static func isEnabled(home: URL, root: URL) throws -> Bool {
        let consent = try readConsent(root: root)
        guard !consent.profiles.isEmpty, let account = try readAccount(home: home) else { return false }
        return consent.profiles.contains(account.fingerprint)
    }

    public static func setEnabled(_ enabled: Bool, home: URL, root: URL, executable: URL, consent: Bool) throws {
        guard !enabled || consent else { throw SwitcherError.message("Confirm the API cost before enabling Astra warmup.") }
        guard executable.isFileURL, executable.path.hasPrefix("/"), !executable.path.contains("\""),
              !executable.path.contains("\n"), ["CodexAccountSwitcher", "WarmupFixture"].contains(executable.lastPathComponent) else {
            throw SwitcherError.message("Invalid Astra warmup executable.")
        }
        guard let account = try readAccount(home: home) else {
            throw SwitcherError.message("Select a file API login before configuring Astra warmup.")
        }
        try PrivateFiles.directory(root)
        let lock = try WarmupFileLock(url: root.appendingPathComponent("astra-warmup-config.lock"))
        try withExtendedLifetime(lock) {
            var settings = try readConsent(root: root)
            settings.profiles.removeAll { $0 == account.fingerprint }
            if enabled { settings.profiles.append(account.fingerprint) }
            let hooksURL = home.appendingPathComponent("hooks.json")
            let consentURL = root.appendingPathComponent(consentName)
            let oldHooks = try PrivateFiles.read(hooksURL)
            let oldConsent = try PrivateFiles.read(consentURL)
            let updatedHooks = try editHooks(oldHooks, install: !settings.profiles.isEmpty, executable: executable)
            do {
                if let updatedHooks, updatedHooks != oldHooks {
                    if let oldHooks {
                        let backup = home.appendingPathComponent("hooks.astra-warmup-backup-\(UUID().uuidString).json")
                        try PrivateFiles.write(oldHooks, to: backup)
                    }
                    try PrivateFiles.write(updatedHooks, to: hooksURL)
                }
                try PrivateFiles.write(JSONEncoder().encode(settings), to: consentURL)
            } catch {
                if let oldHooks { try? PrivateFiles.write(oldHooks, to: hooksURL) }
                else { try? PrivateFiles.remove(hooksURL) }
                if let oldConsent { try? PrivateFiles.write(oldConsent, to: consentURL) }
                else { try? PrivateFiles.remove(consentURL) }
                throw error
            }
        }
    }

    private static func isOwned(_ handler: [String: Any]) throws -> Bool {
        guard handler["statusMessage"] as? String == statusMessage else { return false }
        guard handler["type"] as? String == "command", let command = handler["command"] as? String,
              command.first == "\"", command.hasSuffix("\" --astra-warmup") else {
            throw SwitcherError.message("A conflicting Astra warmup hook exists.")
        }
        let path = String(command.dropFirst().dropLast("\" --astra-warmup".count))
        guard path.hasPrefix("/"), !path.contains("\""), !path.contains("\n"),
              ["CodexAccountSwitcher", "WarmupFixture"].contains(URL(fileURLWithPath: path).lastPathComponent) else {
            throw SwitcherError.message("A conflicting Astra warmup hook exists.")
        }
        return true
    }

    private static func editHooks(_ original: Data?, install: Bool, executable: URL) throws -> Data? {
        var document: [String: Any]
        if let original {
            guard original.count <= 1_048_576,
                  let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SwitcherError.message("Hook settings are invalid.")
            }
            document = parsed
        } else { document = [:] }
        guard document["hooks"] == nil || document["hooks"] is [String: Any] else {
            throw SwitcherError.message("Hook settings are invalid.")
        }
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        for value in hooks.values {
            guard let groups = value as? [[String: Any]], groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
                throw SwitcherError.message("Hook settings are invalid.")
            }
        }
        let command = "\"\(executable.path)\" --astra-warmup"
        var groups = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
        var found = 0
        var changed = false
        var edited: [[String: Any]] = []
        for var group in groups {
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            var kept: [[String: Any]] = []
            var removedOwned = false
            for var handler in handlers {
                if try isOwned(handler) {
                    found += 1
                    if install {
                        if handler["command"] as? String != command { handler["command"] = command; changed = true }
                        if handler["timeout"] as? Int != 40 { handler["timeout"] = 40; changed = true }
                        kept.append(handler)
                    } else { removedOwned = true; changed = true }
                } else { kept.append(handler) }
            }
            group["hooks"] = kept
            if !removedOwned || !kept.isEmpty { edited.append(group) }
        }
        guard found <= 1 else { throw SwitcherError.message("Duplicate Astra warmup hooks exist.") }
        if install && found == 0 {
            edited.append(["hooks": [["type": "command", "command": command, "timeout": 40, "statusMessage": statusMessage]]])
            changed = true
        }
        if !changed { return nil }
        groups = edited
        hooks["UserPromptSubmit"] = groups
        document["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    public static func run(event: Data, home: URL, root: URL) -> Data? {
        run(event: event, home: home, root: root, transport: network)
    }

    static func run(event: Data, home: URL, root: URL, transport: Transport) -> Data? {
        guard event.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: event) as? [String: Any] else { return blockData }
        guard object["hook_event_name"] as? String == "UserPromptSubmit",
              object["model"] as? String == "gpt-6-astra" else { return nil }
        do {
            let settings = try readConsent(root: root)
            if settings.profiles.isEmpty { return nil }
            guard let account = try readAccount(home: home), settings.profiles.contains(account.fingerprint) else { return nil }
            if hasEnvironmentOverride(home: home) { return blockData }
            guard let session = object["session_id"] as? String,
                  session.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return blockData }
            let directory = root.appendingPathComponent("astra-warmup-sessions")
            try PrivateFiles.directory(directory)
            let name = digest(account.fingerprint + "\n" + session)
            let lock = try WarmupFileLock(url: directory.appendingPathComponent(name + ".lock"))
            return try withExtendedLifetime(lock) {
                let marker = directory.appendingPathComponent(name)
                if let value = try PrivateFiles.read(marker) { return value == Data("completed".utf8) ? nil : blockData }
                var request = URLRequest(url: URL(string: account.endpoint + "/responses")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
                request.setValue("Bearer " + account.key, forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "gpt-5.6-sol", "input": "Reply only OK.", "reasoning": ["effort": "low"],
                    "tools": [], "stream": true, "store": false, "max_output_tokens": 256
                ])
                let result = try transport(request)
                guard (200..<300).contains(result.status), result.data.count <= maximumResponse,
                      successful(result.data, contentType: result.contentType) else { return blockData }
                try PrivateFiles.write(Data("completed".utf8), to: marker)
                return nil
            }
        } catch { return blockData }
    }

    private static func hasEnvironmentOverride(home: URL) -> Bool {
        let env = ProcessInfo.processInfo.environment
        for name in ["OPENAI_BASE_URL", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
                     "CODEX_AUTH_JSON", "CODEX_PROFILE", "CODEX_SQLITE_HOME"] {
            if !(env[name] ?? "").isEmpty { return true }
        }
        if let configured = env["CODEX_HOME"], !configured.isEmpty,
           URL(fileURLWithPath: configured).standardizedFileURL.path != home.standardizedFileURL.path { return true }
        return false
    }

    private static func successful(_ data: Data, contentType: String) -> Bool {
        if contentType.lowercased().contains("application/json") {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["status"] as? String == "completed"
        }
        guard contentType.lowercased().contains("text/event-stream"), let text = String(data: data, encoding: .utf8) else { return false }
        var complete = false
        for block in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            var name = ""
            var lines: [String] = []
            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("event:") { name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            }
            if ["error", "response.failed", "response.incomplete"].contains(name) { return false }
            if name == "response.completed" {
                let payload = Data(lines.joined(separator: "\n").utf8)
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      object["type"] as? String == "response.completed",
                      let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else { return false }
                complete = true
            }
        }
        return complete
    }

    private static func network(_ request: URLRequest) throws -> (status: Int, contentType: String, data: Data) {
        let receiver = WarmupReceiver(maximum: maximumResponse)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        guard receiver.finished.wait(timeout: .now() + 20) == .success else {
            task.cancel(); session.invalidateAndCancel()
            throw SwitcherError.message("Astra warmup timed out.")
        }
        session.finishTasksAndInvalidate()
        guard receiver.error == nil, let response = receiver.response, !receiver.tooLarge else {
            throw SwitcherError.message("Astra warmup request failed.")
        }
        return (response.statusCode, response.value(forHTTPHeaderField: "Content-Type") ?? "", receiver.data)
    }
}

private final class WarmupFileLock {
    private let fd: Int32
    init(url: URL) throws {
        try PrivateFiles.check(url)
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SwitcherError.message("Cannot create Astra warmup lock.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid() else {
            close(fd); throw SwitcherError.message("Unsafe Astra warmup lock.")
        }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK || Date() >= deadline {
                close(fd); throw SwitcherError.message("Astra warmup lock timed out.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

private final class WarmupReceiver: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let finished = DispatchSemaphore(value: 0)
    let maximum: Int
    var response: HTTPURLResponse?
    var data = Data()
    var error: Error?
    var tooLarge = false
    init(maximum: Int) { self.maximum = maximum }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(maximum) { tooLarge = true; completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        if data.count + chunk.count > maximum { tooLarge = true; dataTask.cancel() }
        else { data.append(chunk) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = error
        finished.signal()
    }
}
