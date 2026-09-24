import Foundation

struct CatalogUpdate: Codable {
    let previous: Data?
    let next: Data
}

struct Journal: Codable {
    var version = 1
    let previous: Registry
    let oldAuth: Data?
    let oldConfig: Data?
    let newAuth: Data
    let newConfig: Data
    // Optional so pending recovery records from v0.2.0 remain readable.
    var catalogUpdate: CatalogUpdate? = nil
}

public final class SwitcherEngine {
    public let home: URL
    public let vault: Vault
    private let quiescent: () throws -> Void
    // Failure injection is supplied only by tests, never by environment variables.
    private let checkpoint: (String) throws -> Void
    public init(home: URL, vault: Vault, quiescent: @escaping () throws -> Void,
                checkpoint: @escaping (String) throws -> Void = { _ in }) {
        self.home = home; self.vault = vault; self.quiescent = quiescent; self.checkpoint = checkpoint
    }
    private var authURL: URL { home.appendingPathComponent("auth.json") }
    private var configURL: URL { home.appendingPathComponent("config.toml") }
    private var catalogURL: URL { vault.root.appendingPathComponent("api-models.json") }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let lock = try OperationLock(directory: vault.root)
        return try withExtendedLifetime(lock) { try operation() }
    }
    private func readRegistry() throws -> Registry {
        let registry = try vault.load(Registry.self, name: "profiles.enc") ?? Registry()
        try registry.validate()
        return registry
    }
    private func noPending() throws {
        guard try PrivateFiles.read(vault.root.appendingPathComponent("pending.enc")) == nil else {
            throw SwitcherError.message("发现未完成切换。请先退出 Codex，再点「恢复未完成切换」。")
        }
    }
    public func status() throws -> Registry { try locked { try readRegistry() } }
    public func hasPending() throws -> Bool { try locked { try PrivateFiles.read(vault.root.appendingPathComponent("pending.enc")) != nil } }
    private func configText(_ data: Data?) throws -> String {
        guard let data else { return "" }
        guard let text = String(data: data, encoding: .utf8) else { throw SwitcherError.message("config.toml 不是 UTF-8；未修改配置。") }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
    private func sameAccount(_ profile: Profile, auth: Data, route: Route) throws -> Bool {
        let current = try Credential(auth), saved = try Credential(profile.auth)
        guard current.kind == profile.kind, current.identity == saved.identity else { return false }
        if current.kind == .chatgpt { return true }
        return try ConfigEditor.endpoint(route) == ConfigEditor.endpoint(profile.route)
    }
    private func syncCurrent(_ registry: inout Registry) throws {
        guard let auth = try PrivateFiles.read(authURL) else {
            guard registry.activeID == nil else { throw SwitcherError.message("当前登录文件丢失。请恢复或重新导入，防止覆盖账号。") }
            return
        }
        let text = try configText(PrivateFiles.read(configURL))
        try ConfigEditor.assertFileImport(text)
        let route = try ConfigEditor.capture(text)
        guard let index = try registry.profiles.firstIndex(where: { try sameAccount($0, auth: auth, route: route) }) else {
            throw SwitcherError.message("Codex 当前登录不在账号库中。请先「导入当前登录」，不会覆盖已保存账号。")
        }
        registry.activeID = registry.profiles[index].id
        registry.profiles[index].auth = auth
        registry.profiles[index].route = route
        try registry.profiles[index].validate()
    }
    public func importCurrent(name: String) throws {
        try locked {
            try noPending(); try quiescent()
            guard let auth = try PrivateFiles.read(authURL) else {
                throw SwitcherError.message("未找到文件登录。可点「添加 ChatGPT」完成浏览器登录；不会读取或导出官方钥匙串。")
            }
            let text = try configText(PrivateFiles.read(configURL))
            try ConfigEditor.assertFileImport(text)
            let route = try ConfigEditor.capture(text)
            let profile = try Profile(name: name, auth: auth, route: route)
            var registry = try readRegistry()
            if let index = try registry.profiles.firstIndex(where: { try sameAccount($0, auth: auth, route: route) }) {
                registry.profiles[index].auth = auth; registry.profiles[index].route = route
                registry.activeID = registry.profiles[index].id
            } else {
                registry.profiles.append(profile); registry.activeID = profile.id
            }
            try registry.validate(); try vault.save(registry, name: "profiles.enc")
        }
    }
    public func addChatGPT(name: String, auth: Data, replacing id: UUID? = nil) throws {
        guard try Credential(auth).kind == .chatgpt else { throw SwitcherError.message("浏览器登录没有生成 ChatGPT 凭据。") }
        let profile = try Profile(name: name, auth: auth, route: Route())
        try locked {
            try noPending()
            var registry = try readRegistry()
            let identity = try Credential(auth).identity
            if let duplicate = try registry.profiles.first(where: { try Credential($0.auth).identity == identity }), duplicate.id != id {
                throw SwitcherError.message("这个 ChatGPT 账号已在列表中。请用无痕窗口登录另一个账号。")
            }
            if let id {
                if registry.activeID != nil { try syncCurrent(&registry) }
                guard let index = registry.profiles.firstIndex(where: { $0.id == id }), registry.profiles[index].kind == .chatgpt,
                      try Credential(registry.profiles[index].auth).identity == identity else {
                    throw SwitcherError.message("重新登录的账号与原账号不一致；未覆盖。")
                }
                // Re-login for the active account would be overwritten by its live refresh.
                guard registry.activeID != id else { throw SwitcherError.message("请先切换到另一个配置档，再重新登录此账号。") }
                registry.profiles[index].auth = auth
            } else { registry.profiles.append(profile) }
            try registry.validate(); try vault.save(registry, name: "profiles.enc")
        }
    }
    public func saveAPI(name: String, baseURL: String, model: String, key: String, replacing id: UUID? = nil) throws {
        let route = try ConfigEditor.api(baseURL: baseURL, model: model)
        try locked {
            try noPending()
            var registry = try readRegistry()
            if let id {
                // Reconcile identity so an external account switch cannot bypass active protection.
                if registry.activeID != nil { try syncCurrent(&registry) }
                guard registry.activeID != id, let index = registry.profiles.firstIndex(where: { $0.id == id }), registry.profiles[index].kind == .responsesAPI else {
                    throw SwitcherError.message("只能编辑非活动 API 配置档。请先切换到其他账号。")
                }
                let auth = key.isEmpty ? registry.profiles[index].auth : try Credential.api(key)
                let preserved = ConfigEditor.preservingCatalog(route, from: registry.profiles[index].route)
                registry.profiles[index] = try Profile(id: id, name: name, auth: auth, route: preserved)
            } else { registry.profiles.append(try Profile(name: name, auth: Credential.api(key), route: route)) }
            try registry.validate(); try vault.save(registry, name: "profiles.enc")
        }
    }
    public func rename(_ id: UUID, name: String) throws {
        let name = try Profile.validName(name)
        try locked {
            try noPending()
            var registry = try readRegistry()
            guard let index = registry.profiles.firstIndex(where: { $0.id == id }) else { throw SwitcherError.message("配置档不存在。") }
            registry.profiles[index].name = name
            try vault.save(registry, name: "profiles.enc")
        }
    }
    public func delete(_ id: UUID) throws {
        try locked {
            try noPending()
            var registry = try readRegistry()
            if registry.activeID != nil { try syncCurrent(&registry) }
            guard registry.profiles.count > 1, registry.activeID != id else { throw SwitcherError.message("不能删除当前或最后一个配置档。") }
            registry.profiles.removeAll { $0.id == id }
            try vault.save(registry, name: "profiles.enc")
        }
    }
    public func activate(_ id: UUID, replacingUnmanagedLogin: Bool = false) throws {
        try locked {
            try noPending(); try quiescent()
            try PrivateFiles.directory(home)
            var registry = try readRegistry()
            let firstTakeover = registry.activeID == nil && replacingUnmanagedLogin
            if !firstTakeover { try syncCurrent(&registry) }
            guard let target = registry.profiles.first(where: { $0.id == id }) else { throw SwitcherError.message("配置档不存在。") }
            try target.validate()
            let oldAuth = try PrivateFiles.read(authURL), oldConfig = try PrivateFiles.read(configURL)
            var route = target.route
            var update: CatalogUpdate?
            if target.kind == .responsesAPI {
                let configured = try ConfigEditor.catalog(route)
                // Leave explicit user catalogs alone, even if the cache is newer.
                if configured == nil || configured == catalogURL.path {
                    let previous = try PrivateFiles.read(catalogURL)
                    let cache = try? PrivateFiles.read(home.appendingPathComponent("models_cache.json"))
                    let next = ModelCatalog.validated(cache) ?? ModelCatalog.validated(previous)
                    route = try ConfigEditor.withCatalog(route, path: next == nil ? nil : catalogURL.path)
                    if let next, next != previous { update = CatalogUpdate(previous: previous, next: next) }
                }
            }
            let newConfig = Data(try ConfigEditor.applying(route, to: configText(oldConfig)).utf8)
            let journal = Journal(previous: registry, oldAuth: oldAuth, oldConfig: oldConfig, newAuth: target.auth, newConfig: newConfig, catalogUpdate: update)
            // Explicit first-use takeover can replace a stale file while Codex used
            // Keychain/auto. Keep the original file/config encrypted, even on success.
            if firstTakeover, try PrivateFiles.read(vault.root.appendingPathComponent("first-login-backup.enc")) == nil {
                try vault.save(journal, name: "first-login-backup.enc")
            }
            try vault.save(journal, name: "pending.enc")
            do {
                // Check again immediately before writing, after any Keychain prompt.
                try quiescent()
                guard try PrivateFiles.read(authURL) == oldAuth, try PrivateFiles.read(configURL) == oldConfig else {
                    throw SwitcherError.message("登录或配置被其他程序修改，已停止切换。")
                }
                if let update {
                    guard try PrivateFiles.read(catalogURL) == update.previous else { throw SwitcherError.message("模型目录被其他程序修改，已停止切换。") }
                    try PrivateFiles.write(update.next, to: catalogURL)
                    try checkpoint("catalog")
                }
                try PrivateFiles.write(newConfig, to: configURL)
                try checkpoint("config")
                try PrivateFiles.write(target.auth, to: authURL)
                try checkpoint("auth")
                guard try PrivateFiles.read(authURL) == target.auth, try PrivateFiles.read(configURL) == newConfig else {
                    throw SwitcherError.message("切换后文件校验失败。")
                }
                if let update, try PrivateFiles.read(catalogURL) != update.next { throw SwitcherError.message("模型目录写入校验失败。") }
                registry.activeID = id
                try vault.save(registry, name: "profiles.enc")
                try checkpoint("registry")
                try vault.remove("pending.enc")
            } catch {
                do { try recoverUnlocked() }
                catch { throw SwitcherError.message("切换未完成，自动恢复未成功。请退出 Codex 后点「恢复未完成切换」；保留账号库。") }
                throw error
            }
        }
    }
    public func recover() throws { try locked { try recoverUnlocked() } }
    private func recoverUnlocked() throws {
        try quiescent()
        guard let record = try vault.load(Journal.self, name: "pending.enc") else { return }
        guard record.version == 1 else { throw SwitcherError.message("恢复记录版本不支持。") }
        try record.previous.validate()
        let auth = try PrivateFiles.read(authURL), config = try PrivateFiles.read(configURL)
        guard (auth == record.oldAuth || auth == record.newAuth), (config == record.oldConfig || config == record.newConfig) else {
            throw SwitcherError.message("中断后登录或配置被外部修改，拒绝覆盖。请备份账号库和 .codex 后人工排查。")
        }
        if let update = record.catalogUpdate {
            let current = try PrivateFiles.read(catalogURL)
            guard current == update.previous || current == update.next else { throw SwitcherError.message("中断后模型目录被外部修改，拒绝覆盖。") }
            if let previous = update.previous { try PrivateFiles.write(previous, to: catalogURL) } else { try PrivateFiles.remove(catalogURL) }
        }
        if let data = record.oldConfig { try PrivateFiles.write(data, to: configURL) } else { try PrivateFiles.remove(configURL) }
        if let data = record.oldAuth { try PrivateFiles.write(data, to: authURL) } else { try PrivateFiles.remove(authURL) }
        try vault.save(record.previous, name: "profiles.enc")
        try vault.remove("pending.enc")
    }
}
