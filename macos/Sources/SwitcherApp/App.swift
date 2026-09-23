import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwitcherCore

enum Theme {
    static let navy = Color(red: 0.09, green: 0.21, blue: 0.35)
    static let blue = Color(red: 0.16, green: 0.40, blue: 0.78)
    static let teal = Color(red: 0.20, green: 0.57, blue: 0.52)
    static let canvas = Color(red: 0.95, green: 0.97, blue: 0.99)
}

@MainActor final class SwitcherModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var activeID: UUID?
    @Published var busy = false
    @Published var loggingIn = false
    @Published var pending = false
    @Published var message = ""
    @Published var errorText = ""
    @Published var form: FormMode?
    let runtime = MacRuntime()
    let preview: Bool
    let home: URL
    let root: URL
    var engine: SwitcherEngine?
    init(preview: Bool = false) {
        self.preview = preview
        let user = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        home = user.appendingPathComponent(".codex")
        root = user.appendingPathComponent("Library/Application Support/CodexAccountSwitcher")
        if preview {
            let auth = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"demo","access_token":"FAKE","refresh_token":"FAKE","id_token":"FAKE"}}"#.utf8)
            if let personal = try? Profile(name: "个人", auth: auth, route: Route()),
               let apiAuth = try? Credential.api("DEMO_NOT_A_REAL_KEY"),
               let route = try? ConfigEditor.api(baseURL: "https://api.example.com/v1", model: "your-model"),
               let lab = try? Profile(name: "实验室", auth: apiAuth, route: route) {
                profiles = [personal, lab]; activeID = personal.id
            }
            return
        }
        let vault = Vault(root: root, keyProvider: { [root] in
            let existing = FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles.enc").path) || FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.enc").path)
            return try KeychainKey.loadOrCreate(allowCreate: !existing)
        })
        engine = SwitcherEngine(home: home, vault: vault, quiescent: { [home] in
            try MacRuntime.assertDefaultHome(home)
            try MacRuntime.assertQuiescent()
        })
    }
    func reload() {
        guard let engine, !preview else { return }
        do {
            let status = try engine.status()
            profiles = status.profiles; activeID = status.activeID; pending = try engine.hasPending()
        } catch { errorText = error.localizedDescription }
    }
    func confirm(_ title: String, _ detail: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: action); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func perform(_ work: @escaping () throws -> Void, success: String) {
        guard !busy, !preview else { return }
        busy = true; errorText = ""; message = "正在保存…"
        Task {
            do { try await Task.detached { try work() }.value; message = success }
            catch { message = ""; errorText = error.localizedDescription }
            busy = false; reload()
        }
    }
    func activate(_ profile: Profile) {
        guard !busy, let engine, !preview else { return }
        let warning = profile.kind == .responsesAPI ? "继续已有会话可能将历史发送给这个 API 服务商。仅使用可信服务。\n\n" : ""
        let takeover = activeID == nil
        let firstUse = takeover ? "首次启用会改用 file 登录并替换现有 auth.json；旧文件和配置会加密备份，官方钥匙串不改动。\n\n" : ""
        guard confirm("切换到「\(profile.name)」？", warning + firstUse + "请先结束任务。工具会正常退出并重开 Codex；不会强制结束 CLI 或编辑器任务。本地历史、项目及工作区仍然共用。", action: "切换并打开") else { return }
        busy = true; errorText = ""; message = "正在退出 Codex…"
        Task {
            do {
                try await runtime.quitDesktop()
                message = "正在切换账号…"
                try await Task.detached { try engine.activate(profile.id, replacingUnmanagedLogin: takeover) }.value
                reload(); message = "账号已切换，正在打开 Codex…"
                try await runtime.openDesktop()
                message = "已切换到「\(profile.name)」。"
            } catch { message = ""; errorText = error.localizedDescription }
            busy = false; reload()
        }
    }
    func importCurrent(_ name: String) {
        guard let engine, !busy else { return }
        guard confirm("导入当前文件登录？", "请先结束任务并退出 Codex。只保存当前 auth.json 的加密副本，不读取官方钥匙串，不复制历史。", action: "导入") else { return }
        perform({ try engine.importCurrent(name: name) }, success: "当前登录已导入。")
    }
    func login(_ name: String, replacing id: UUID? = nil) {
        guard let engine, !busy, !preview else { return }
        busy = true; loggingIn = true; errorText = ""; message = "请在浏览器完成登录。当前 Codex 账号不会改变。"
        runtime.beginLogin()
        let runtime = self.runtime, root = self.root
        Task {
            do {
                let auth = try await Task.detached { try runtime.enroll(root: root) }.value
                try await Task.detached { try engine.addChatGPT(name: name, auth: auth, replacing: id) }.value
                message = "登录已保存。点击配置档即可切换。"
            } catch { message = ""; errorText = error.localizedDescription }
            loggingIn = false; busy = false; reload()
        }
    }
    func delete(_ profile: Profile) {
        guard let engine, confirm("删除「\(profile.name)」？", "只移除切换器保存的凭据，不删除 Codex 历史或项目。再次添加需要重新登录。", action: "删除") else { return }
        perform({ try engine.delete(profile.id) }, success: "配置档已删除，本地历史未改动。")
    }
    func recover() {
        guard let engine, confirm("恢复未完成切换？", "请先退出桌面、CLI 和编辑器中的 Codex。将恢复切换前认证和配置；若发现外部修改则停止。", action: "恢复") else { return }
        perform({ try engine.recover() }, success: "恢复检查完成。")
    }
    func chooseApp() {
        let panel = NSOpenPanel(); panel.title = "选择官方 Codex.app"
        panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            do { try runtime.selectDesktop(url); message = "已选择 Codex.app。" }
            catch { errorText = error.localizedDescription }
        }
    }
    func chooseCLI() {
        let panel = NSOpenPanel(); panel.title = "选择官方 codex 可执行文件（仅用于登录）"; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) {
            UserDefaults.standard.set(url.path, forKey: "codexCLIPath")
            message = "已设置登录组件。只选择从 OpenAI 官方来源安装的程序。"
        }
    }
}

struct FormMode: Identifiable {
    enum Kind { case chatgpt, api, rename, current }
    let id = UUID()
    let kind: Kind
    var profile: Profile? = nil
}

struct ProfileForm: View {
    @ObservedObject var model: SwitcherModel
    let mode: FormMode
    @Environment(\.dismiss) var dismiss
    @State var name = ""
    @State var baseURL = ""
    @State var modelName = ""
    @State var key = ""
    @State var validation = ""
    var title: String {
        switch mode.kind {
        case .chatgpt: return "添加 ChatGPT 账号"
        case .api: return mode.profile == nil ? "添加 Responses API" : "编辑 Responses API"
        case .rename: return "重命名配置档"
        case .current: return "导入当前登录"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 22, weight: .semibold, design: .rounded))
            TextField("名称，例如：个人 / 工作", text: $name).textFieldStyle(.roundedBorder)
            if mode.kind == .api {
                TextField("Base URL，例如 https://api.example.com/v1", text: $baseURL).textFieldStyle(.roundedBorder)
                TextField("服务商提供的模型名", text: $modelName).textFieldStyle(.roundedBorder)
                SecureField(mode.profile == nil ? "API Key" : "API Key（留空保留原 Key）", text: $key).textFieldStyle(.roundedBorder)
                Text("只支持 Responses API。继续原会话可能把历史发给新服务商。保存仅校验格式，不发起付费请求。").font(.caption).foregroundStyle(.secondary)
            } else if mode.kind == .chatgpt {
                Text("使用官方浏览器登录。添加过程使用临时目录，不改变当前账号。浏览器自动选错账号时，可用无痕窗口打开登录链接。").font(.callout).foregroundStyle(.secondary)
            } else if mode.kind == .current {
                Text("导入 ~/.codex/auth.json。若当前只用钥匙串登录，请改用「添加 ChatGPT」，不用手工复制 token。").font(.callout).foregroundStyle(.secondary)
            }
            if !validation.isEmpty { Text(validation).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode.kind == .chatgpt ? "浏览器登录" : "保存") { submit() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 470)
            .onAppear {
                name = mode.profile?.name ?? ""
                if let profile = mode.profile {
                    baseURL = (try? ConfigEditor.endpoint(profile.route)) ?? ""
                    modelName = (try? ConfigEditor.model(profile.route)) ?? ""
                }
            }
    }
    func submit() {
        do {
            let name = try Profile.validName(name)
            guard let engine = model.engine else { return }
            if mode.kind == .api {
                _ = try ConfigEditor.api(baseURL: baseURL, model: modelName)
                if mode.profile == nil || !key.isEmpty { _ = try Credential.api(key) }
                let url = baseURL, selectedModel = modelName, secret = key, id = mode.profile?.id
                model.perform({ try engine.saveAPI(name: name, baseURL: url, model: selectedModel, key: secret, replacing: id) }, success: "API 配置档已保存。")
            } else if mode.kind == .chatgpt { model.login(name) }
            else if mode.kind == .current { model.importCurrent(name) }
            else if let profile = mode.profile { model.perform({ try engine.rename(profile.id, name: name) }, success: "名称已更新。") }
            key = ""; dismiss()
        } catch { validation = error.localizedDescription }
    }
}

struct PickerView: View {
    @ObservedObject var model: SwitcherModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("CODEX ACCOUNT SWITCHER", systemImage: "arrow.left.arrow.right").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.3).foregroundStyle(Theme.blue)
                    Text("切换账号，接着做。").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.navy)
                    Text("选择这次使用的登录或 API 配置档。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("选择 Codex.app…", action: model.chooseApp)
                    Button("选择官方登录组件…", action: model.chooseCLI)
                    Divider()
                    Button("打开共享数据目录") { NSWorkspace.shared.open(model.home) }
                    Button("打开账号库目录") { NSWorkspace.shared.open(model.root) }
                    Button("恢复未完成切换…", action: model.recover)
                } label: { Image(systemName: "gearshape").font(.title3) }.menuStyle(.borderlessButton).frame(width: 28).disabled(model.busy)
            }.padding(28)
            HStack {
                Text("\(model.profiles.count) 个配置档").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导入当前登录") { model.form = FormMode(kind: .current) }
                Menu("＋ 添加") {
                    Button("ChatGPT 账号") { model.form = FormMode(kind: .chatgpt) }
                    Button("Responses API") { model.form = FormMode(kind: .api) }
                }.menuStyle(.borderlessButton).frame(width: 90)
            }.padding(.horizontal, 28).disabled(model.busy || model.pending)
            ScrollView {
                VStack(spacing: 12) {
                    if model.profiles.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 34)).foregroundStyle(Theme.blue)
                            Text("先添加你的第一个账号").font(.headline)
                            Text("已有文件登录可直接导入；也可以通过浏览器添加。\n首次使用前，请备份 ~/.codex。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    ForEach(model.profiles) { profile in accountRow(profile) }
                }.padding(28).padding(.top, -12)
            }
            VStack(alignment: .leading, spacing: 10) {
                if model.pending { Button("发现未完成切换 · 点击恢复", action: model.recover).disabled(model.busy).foregroundStyle(.orange) }
                if model.busy { HStack { ProgressView().controlSize(.small); Text(model.message).font(.caption) } }
                else if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(Theme.teal) }
                if !model.errorText.isEmpty { Text(model.errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if model.loggingIn {
                    HStack {
                        Button("打开登录页面") { if let url = model.runtime.browserURL { NSWorkspace.shared.open(url) } }
                        Button("复制登录链接") { if let url = model.runtime.browserURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) } }
                        Button("取消登录", action: model.runtime.cancelLogin)
                    }.font(.caption)
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Theme.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("一份本地工作区，多个账号入口").font(.caption.weight(.semibold))
                        Text("会话 · 项目 · skills · 插件 · MCP 共用；云端内容随账号而定。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(22).background(Color.white.opacity(0.7))
        }.frame(minWidth: 620, idealWidth: 660, minHeight: 590, idealHeight: 650)
            .background(Theme.canvas).tint(Theme.blue).preferredColorScheme(.light)
            .sheet(item: $model.form) { ProfileForm(model: model, mode: $0) }
            .onAppear { model.reload() }
    }
    func accountRow(_ profile: Profile) -> some View {
        HStack(spacing: 14) {
            Button { model.activate(profile) } label: {
                HStack(spacing: 14) {
                    Image(systemName: profile.kind == .chatgpt ? "person.crop.circle" : "network").font(.system(size: 25)).foregroundStyle(profile.kind == .chatgpt ? Theme.blue : Theme.teal).frame(width: 36)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(profile.name).font(.system(size: 17, weight: .semibold))
                            if model.activeID == profile.id { Text("当前").font(.caption.weight(.medium)).foregroundStyle(Theme.teal).padding(.horizontal, 7).padding(.vertical, 2).background(Theme.teal.opacity(0.10), in: Capsule()) }
                        }
                        Text(detail(profile)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.forward").foregroundStyle(Theme.blue)
                }.padding(18).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("切换并打开 \(profile.name)")
            Menu {
                Button("重命名") { model.form = FormMode(kind: .rename, profile: profile) }
                if profile.kind == .responsesAPI {
                    Button("编辑 API") { model.form = FormMode(kind: .api, profile: profile) }.disabled(model.activeID == profile.id)
                } else {
                    Button("重新登录") { model.login(profile.name, replacing: profile.id) }.disabled(model.activeID == profile.id)
                }
                Divider()
                Button("删除", role: .destructive) { model.delete(profile) }.disabled(model.activeID == profile.id || model.profiles.count <= 1)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).padding(.trailing, 16)
        }.background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.activeID == profile.id ? Theme.teal.opacity(0.6) : Color.gray.opacity(0.18), lineWidth: 1))
            .disabled(model.busy || model.pending)
    }
    func detail(_ profile: Profile) -> String {
        if profile.kind == .chatgpt { return "ChatGPT 登录" }
        let endpoint = (try? ConfigEditor.endpoint(profile.route)) ?? "https://api.openai.com/v1"
        let host = URL(string: endpoint)?.host ?? "API"
        let modelName = (try? ConfigEditor.model(profile.route)) ?? ""
        return "Responses API · \(host)" + (modelName.isEmpty ? "" : " · \(modelName)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SwitcherApplication.sharedModel.busy {
            let alert = NSAlert(); alert.messageText = "请等待当前操作完成。"
            alert.informativeText = "浏览器登录可先点击「取消登录」。切换过程中不要退出。"
            alert.runModal(); return .terminateCancel
        }
        return .terminateNow
    }
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--render-preview"), args.count > index + 1 {
            let renderer = ImageRenderer(content: PickerView(model: SwitcherApplication.sharedModel).frame(width: 660, height: 650))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try png.write(to: URL(fileURLWithPath: args[index + 1])); exit(0) } catch { exit(1) }
        }
    }
}

@main struct SwitcherApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @MainActor static let sharedModel = SwitcherModel(preview: ProcessInfo.processInfo.arguments.contains("--render-preview"))
    var body: some Scene {
        WindowGroup("Codex Account Switcher") { PickerView(model: Self.sharedModel) }
            .windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
