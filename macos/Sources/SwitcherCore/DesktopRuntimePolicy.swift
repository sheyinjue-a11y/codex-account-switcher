import Foundation

// Keep process and environment decisions separate from AppKit so they can be
// checked with isolated snapshots, without opening or closing a real account.
public enum DesktopRuntimePolicy {
    public static let environmentOverrides = [
        "CODEX_HOME", "CODEX_SQLITE_HOME", "CODEX_ELECTRON_USER_DATA_PATH",
        "OPENAI_BASE_URL", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_PROFILE",
        "CODEX_ACCESS_TOKEN", "CODEX_AUTH_JSON",
        "CODEX_APP_SERVER_OPENAI_BASE_URL", "CODEX_APP_SERVER_CHATGPT_BASE_URL"
    ]

    public static func canImportCurrent(authExists: Bool, configuration: Data?) -> Bool {
        guard authExists else { return false }
        var text = ""
        if let configuration {
            guard let decoded = String(data: configuration, encoding: .utf8) else { return false }
            text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        }
        do { try ConfigEditor.assertFileImport(text); return true }
        catch { return false }
    }

    public static func loginEnvironment(_ inherited: [String: String], home: URL) -> [String: String] {
        var environment = inherited
        for name in environmentOverrides { environment.removeValue(forKey: name) }
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        return environment
    }

    public static func loginCandidates(selected: String?, desktop: URL?, userHome: String) -> [String] {
        var paths: [String] = []
        if let selected, !selected.isEmpty { paths.append(selected) }
        if let desktop {
            for name in ["codex", "bin/codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"] {
                paths.append(desktop.appendingPathComponent("Contents/Resources/" + name).path)
            }
        }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", userHome + "/.local/bin/codex"]
        return paths
    }

    private struct RunningProcess {
        let id: Int32
        let parentID: Int32
        let path: String
    }

    private static func processes(_ snapshot: String) -> [RunningProcess] {
        snapshot.split(separator: "\n").compactMap { row in
            let fields = row.trimmingCharacters(in: .whitespaces).split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let id = Int32(fields[0]), let parentID = Int32(fields[1]) else { return nil }
            return RunningProcess(id: id, parentID: parentID, path: String(fields[2]))
        }
    }

    private static func hasBundledProcess(_ snapshot: String, app: URL, owned: inout Set<Int32>) -> Bool {
        let running = processes(snapshot)
        // Keep the original descendants after the main process exits and macOS
        // reparents them. An independent CLI using the same binary is not ours.
        var previousCount: Int
        repeat {
            previousCount = owned.count
            for process in running where owned.contains(process.parentID) { owned.insert(process.id) }
        } while previousCount != owned.count
        let prefix = app.resolvingSymlinksInPath().path + "/"
        return running.contains { process in
            // Independent CLI/editor tasks are checked separately by the engine.
            // Only descendants whose executable belongs to this app delay exit.
            guard owned.contains(process.id), process.path.contains(".app/") else { return false }
            return URL(fileURLWithPath: process.path).resolvingSymlinksInPath().path.hasPrefix(prefix)
        }
    }

    @MainActor public static func waitForDesktopExit(
        app: URL,
        processIDs: Set<Int32>,
        initialSnapshot: String,
        isTerminated: () -> Bool,
        processSnapshot: () async throws -> String,
        timeout: TimeInterval = 10,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
    ) async throws {
        var owned = processIDs
        _ = hasBundledProcess(initialSnapshot, app: app, owned: &owned)
        let deadline = now() + timeout
        while true {
            let helpersRunning = hasBundledProcess(try await processSnapshot(), app: app, owned: &owned)
            if isTerminated(), !helpersRunning { return }
            guard now() < deadline else {
                throw SwitcherError.message("Codex 或其后台组件未正常退出。请保存任务并手动退出后重试。")
            }
            try await sleep()
        }
    }
}
