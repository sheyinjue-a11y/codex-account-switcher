# 开发与验证

运行入口在 `tools/chatgpt-account-switch`。保留历史文件名以兼容已有快捷方式，用户入口是仓库根目录的 `Setup.cmd` / `Start.cmd`。

- `Switch-ChatGPTAccount.ps1`：环境、进程互斥、文件写入、旧版兼容和 CLI。
- `ProfileRegistry.ps1`：schema 2 注册表校验和 CRUD。
- `ProfileManagement.ps1`：登录、API 档、事务、迁移及首次导入。
- `Start-ChatGPT.ps1` / `AccountPicker.xaml` / `ProfileDialogs.ps1`：WPF 界面。
- `Invoke-ChatGPTSwitch.ps1`：隔离执行与脱敏结果协议。
- `AstraWarmup.ps1` / `Invoke-AstraWarmup.ps1` / `Configure-AstraWarmup.ps1`：可选预热、非 GUI hook 入口与费用确认界面。
- `Test-*.ps1` / `Test-SharedSessions.py`：假凭据离线回归。

## 检查

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\chatgpt-account-switch\Test-All.ps1 -SkipSharedSessions
python -m pip install -r requirements-test.txt
python tools\chatgpt-account-switch\Test-SharedSessions.py
python tools\chatgpt-account-switch\Test-AstraWarmupIntegration.py
git diff --check
```

Windows 测试需 Windows PowerShell 5.1、WPF；WPF 检查使用 STA。共享会话检查另需可执行的官方 `codex.exe`，可通过 `--codex` 指定。Windows CI 跑离线套件，不接触真实账号或服务。

预热集成测试同样接受 `--codex`，使用官方 app-server 与本机模拟 Responses 服务。它只在一次性测试目录内批准经检查的测试 hook，验证生产安装器没有自动批准信任；生产代码不得复制这一批准步骤。测试验证请求顺序、固定低推理请求、原消息保留、重复去重与失败拦截，不把模拟成功等同于真实服务商可用。

修改认证、路由或恢复行为时，添加能检出缺陷的回归测试。不得在测试里读取真实用户凭据，不得自动发送真实模型请求。真实 OAuth 和桌面验收由用户手动完成。

公开发行内容由 `scripts/Export-PublicRelease.ps1` 的显式清单生成。它不会打包 `.git`、个人历史说明、官方图标、会话或账号库；若目标目录已有文件则拒绝覆盖。新增运行依赖时同时更新清单。

## macOS

- `macos/Sources/SwitcherCore`：配置根项编辑、认证校验、Keychain/AES-GCM、原子文件和恢复事务。
- `macos/Sources/SwitcherApp`：SwiftUI 窗口、官方 Codex 检测/正常退出/重开、隔离浏览器登录。
- `macos/Tests/SwitcherCoreTests`：临时目录和假凭据，不接触用户账号或真实钥匙串。
- `macos/Tests/Fixtures/WarmupFixture`：测试专用原生 hook 驱动，仅接受指定前缀的临时目录，不打包进发布应用。先 `swift build --package-path macos --product WarmupFixture`，再将其完整路径传入预热集成测试的 `--mac-driver`。
- `cd macos && swift test`；根目录运行 `bash macos/scripts/build.sh`。需 Xcode Command Line Tools，无第三方 Swift 包。
- `.github/workflows/macos.yml`：Mac runner 原生测试、arm64/x86_64 构建、合并 Universal、ad-hoc 签名检查和演示界面渲染。仅把 ZIP 和校验文件作为发行资源，不把临时文件或账号库上传。

macOS 保守拒绝不支持的 TOML 根项。修改解析器时测试复杂字符串、重复键、provider 覆盖以及未管理配置的保留。不要将认证错误吞掉后新建空账号库；密钥丢失必须明确阻止写入。
