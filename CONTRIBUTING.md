# 开发与验证

运行入口在 `tools/chatgpt-account-switch`。保留历史文件名以兼容已有快捷方式，用户入口是仓库根目录的 `Setup.cmd` / `Start.cmd`。

- `Switch-ChatGPTAccount.ps1`：环境、进程互斥、文件写入、旧版兼容和 CLI。
- `ProfileRegistry.ps1`：schema 2 注册表校验和 CRUD。
- `ProfileManagement.ps1`：登录、API 档、事务、迁移及首次导入。
- `Start-ChatGPT.ps1` / `AccountPicker.xaml` / `ProfileDialogs.ps1`：WPF 界面。
- `Invoke-ChatGPTSwitch.ps1`：隔离执行与脱敏结果协议。
- `Test-*.ps1` / `Test-SharedSessions.py`：假凭据离线回归。

## 检查

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\chatgpt-account-switch\Test-All.ps1 -SkipSharedSessions
python -m pip install -r requirements-test.txt
python tools\chatgpt-account-switch\Test-SharedSessions.py
git diff --check
```

Windows 测试需 Windows PowerShell 5.1、WPF；WPF 检查使用 STA。共享会话检查另需可执行的官方 `codex.exe`，可通过 `--codex` 指定。Windows CI 跑离线套件，不接触真实账号或服务。

修改认证、路由或恢复行为时，添加能检出缺陷的回归测试。不得在测试里读取真实用户凭据，不得自动发送真实模型请求。真实 OAuth 和桌面验收由用户手动完成。

公开发行内容由 `scripts/Export-PublicRelease.ps1` 的显式清单生成。它不会打包 `.git`、个人历史说明、官方图标、会话或账号库；若目标目录已有文件则拒绝覆盖。新增运行依赖时同时更新清单。

## macOS

- `macos/Sources/SwitcherCore`：配置根项编辑、认证校验、Keychain/AES-GCM、原子文件和恢复事务。
- `macos/Sources/SwitcherApp`：SwiftUI 窗口、官方 Codex 检测/正常退出/重开、隔离浏览器登录。
- `macos/Tests/SwitcherCoreTests`：临时目录和假凭据，不接触用户账号或真实钥匙串。
- `cd macos && swift test`；根目录运行 `bash macos/scripts/build.sh`。需 Xcode Command Line Tools，无第三方 Swift 包。
- `.github/workflows/macos.yml`：Mac runner 原生测试、arm64/x86_64 构建、合并 Universal、ad-hoc 签名检查和演示界面渲染。仅把 ZIP 和校验文件作为发行资源，不把临时文件或账号库上传。

macOS 保守拒绝不支持的 TOML 根项。修改解析器时测试复杂字符串、重复键、provider 覆盖以及未管理配置的保留。不要将认证错误吞掉后新建空账号库；密钥丢失必须明确阻止写入。
