import AppKit
import Foundation
import SwitcherCore

final class MacRuntime {
    private let gate = NSLock()
    private var loginProcess: Process?
    private var cancelled = false
    private var loginLink: URL?
    var browserURL: URL? { gate.lock(); defer { gate.unlock() }; return loginLink }
    var desktop: URL? {
        let stored = UserDefaults.standard.string(forKey: "codexAppPath")
        let candidates = [stored, "/Applications/Codex.app", NSHomeDirectory() + "/Applications/Codex.app"].compactMap { $0 }
        return candidates.map { URL(fileURLWithPath: $0) }.first { validApp($0) }
    }
    func validApp(_ url: URL) -> Bool {
        guard url.pathExtension == "app", url.lastPathComponent != "Codex Account Switcher.app",
              let bundle = Bundle(url: url), let exe = bundle.executableURL,
              let id = bundle.bundleIdentifier, id.lowercased().contains("codex"),
              id != "io.github.sheyinjue-a11y.codex-account-switcher",
              FileManager.default.isExecutableFile(atPath: exe.path) else { return false }
        return true
    }
    func selectDesktop(_ url: URL) throws {
        guard validApp(url) else { throw SwitcherError.message("请选择已安装的官方 Codex.app，不是切换器本身。") }
        UserDefaults.standard.set(url.path, forKey: "codexAppPath")
    }
    func cli() throws -> URL {
        var paths: [String] = []
        if let app = desktop {
            for name in ["codex", "bin/codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"] {
                paths.append(app.appendingPathComponent("Contents/Resources/" + name).path)
            }
        }
        if let selected = UserDefaults.standard.string(forKey: "codexCLIPath") { paths.append(selected) }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.local/bin/codex"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SwitcherError.message("未找到官方登录组件。请先选择 Codex.app；仍找不到时，在设置中选择已安装的官方 codex CLI。")
        }
        return URL(fileURLWithPath: path)
    }
    static func cleanEnvironment(home: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "CODEX_ACCESS_TOKEN", "CODEX_AUTH_JSON", "CODEX_HOME", "CODEX_PROFILE"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = home.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        return env
    }
    static func assertDefaultHome(_ home: URL) throws {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        if !configured.isEmpty && URL(fileURLWithPath: configured).standardizedFileURL.path != home.path {
            throw SwitcherError.message("检测到自定义 CODEX_HOME。本版只管理 ~/.codex，未修改自定义目录。")
        }
        // Finder launches inherit launchd, not the user's interactive shell config.
        for name in ["CODEX_HOME", "CODEX_SQLITE_HOME", "OPENAI_BASE_URL", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_PROFILE", "CODEX_ACCESS_TOKEN", "CODEX_AUTH_JSON"] {
            let inherited = ProcessInfo.processInfo.environment[name] ?? ""
            if !inherited.isEmpty && !(name == "CODEX_HOME" && inherited == home.path) {
                throw SwitcherError.message("切换器启动环境有 \(name) 覆盖。请移除该覆盖后重开工具；未修改系统环境。")
            }
            let result = try capture("/bin/launchctl", ["getenv", name])
            let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !(name == "CODEX_HOME" && value == home.path) {
                throw SwitcherError.message("桌面启动环境有 \(name) 覆盖。请先处理该设置，再切换；工具不会自动更改系统环境。")
            }
        }
    }
    static func capture(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // launchctl getenv returns non-zero for an unset variable.
        if process.terminationStatus != 0 && executable != "/bin/launchctl" { throw SwitcherError.message("无法检查系统进程，未执行切换。") }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func assertQuiescent() throws {
        let output = try capture("/bin/ps", ["-axo", "pid=,comm="])
        let busy = output.split(separator: "\n").contains { row in
            let fields = row.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, Int32(fields[0]) != getpid() else { return false }
            let path = String(fields[1]).lowercased()
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name == "codex" || name.hasPrefix("codex-") || path.contains("/codex.app/")
        }
        if busy { throw SwitcherError.message("Codex 仍在运行。请退出桌面、终端与编辑器中的 Codex 后重试；不会强制结束任务。") }
    }
    @MainActor func quitDesktop() async throws {
        guard let app = desktop else { throw SwitcherError.message("未找到 Codex.app。请在设置中选择官方桌面应用。") }
        let path = app.resolvingSymlinksInPath().path
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == path }
        for process in running { _ = process.terminate() }
        for _ in 0..<100 {
            if running.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SwitcherError.message("Codex 未正常退出。请保存任务并手动退出后重试。")
    }
    @MainActor func openDesktop() async throws {
        guard let app = desktop else { throw SwitcherError.message("账号已切换，但未找到 Codex.app。请在设置中选择应用后重新打开。") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // LaunchServices keeps the existing shared home; do not create per-account homes.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                if error != nil { continuation.resume(throwing: SwitcherError.message("账号已切换，但 Codex 启动失败。请手动打开官方应用。")) }
                else { continuation.resume() }
            }
        }
    }
    func beginLogin() { gate.lock(); cancelled = false; loginLink = nil; gate.unlock() }
    func cancelLogin() {
        gate.lock(); cancelled = true; let process = loginProcess; gate.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    func enroll(root: URL) throws -> Data {
        let executable = try cli()
        let staging = root.appendingPathComponent("login-" + UUID().uuidString)
        try PrivateFiles.directory(staging)
        defer {
            // Only this invocation's UUID directory, never the shared Codex home.
            try? FileManager.default.removeItem(at: staging)
            gate.lock(); loginProcess = nil; loginLink = nil; gate.unlock()
        }
        try PrivateFiles.write(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: staging.appendingPathComponent("config.toml"))
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["login"]
        process.environment = Self.cleanEnvironment(home: staging)
        process.currentDirectoryURL = staging
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        let outputLock = NSLock()
        var output = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            outputLock.lock()
            output.append(chunk)
            if output.count > 32768 { output = output.suffix(32768) }
            let text = String(data: output, encoding: .utf8) ?? ""
            outputLock.unlock()
            if let range = text.range(of: #"https://auth\.openai\.com/[^\s\x1B]+"#, options: .regularExpression), let url = URL(string: String(text[range])) {
                self?.gate.lock(); self?.loginLink = url; self?.gate.unlock()
            }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        gate.lock(); loginProcess = process; let alreadyCancelled = cancelled; gate.unlock()
        if alreadyCancelled { throw SwitcherError.message("登录已取消。") }
        try process.run()
        let deadline = Date().addingTimeInterval(600)
        while process.isRunning {
            gate.lock(); let isCancelled = cancelled; gate.unlock()
            if isCancelled || Date() > deadline {
                process.terminate()
                // This is our isolated login child, never a user's Codex task.
                for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw SwitcherError.message(isCancelled ? "登录已取消；当前账号未改变。" : "登录超时；请重试。")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        gate.lock(); let isCancelled = cancelled; gate.unlock()
        guard !isCancelled, process.terminationStatus == 0,
              let auth = try PrivateFiles.read(staging.appendingPathComponent("auth.json")),
              try Credential(auth).kind == .chatgpt else {
            throw SwitcherError.message(isCancelled ? "登录已取消。" : "浏览器登录未完成。确认登录的是目标账号，然后重试。")
        }
        return auth
    }
}
