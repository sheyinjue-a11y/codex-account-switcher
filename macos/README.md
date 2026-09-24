# macOS 原生桌面版（v0.3.0 预览）

这是切换 **官方 Codex 桌面应用** 的原生 SwiftUI 工具，不是 CLI 界面的替代品。日常点击操作，不需要终端或开发环境。工具支持 macOS 13+，Universal 二进制包含 Apple Silicon 和 Intel；官方 Codex 自身的系统/芯片要求仍以官方为准。

## 安装与使用

1. 先安装官方 Codex.app。首次使用前退出 Codex，备份 `~/.codex`；备份可能包含凭据和私密会话，切勿上传。
2. 从本仓库 Releases 下载 `Codex-Account-Switcher-macOS-universal.zip`，解压，将 **Codex Account Switcher.app** 拖到「应用程序」，双击打开。
3. 本预览版只有 ad-hoc 签名，**没有 Apple Developer ID 签名或公证**。macOS 可能阻止首次打开。核验来源和 SHA256 后，如你信任该软件，由你本人在系统「隐私与安全性」确认是否允许；企业策略不允许时不要绕过。不要全局关闭 Gatekeeper 或移除安全属性。
4. 已有 `~/.codex/auth.json` 文件登录时，退出 Codex 后点「导入当前登录」。如果用钥匙串/auto 登录，点「＋ 添加 → ChatGPT 账号」完成官方浏览器登录，不用手工复制 token；首次切换会将本地认证存储设为 `file`。
5. 添加其他 ChatGPT 账号或 Responses API。点击账号卡片，确认后工具会正常退出 Codex、切换并重开。先结束正在执行的任务；CLI/编辑器仍运行时会停止切换，不强制杀进程。

默认查找 `/Applications/Codex.app` 和 `~/Applications/Codex.app`。其他安装位置可用右上角设置选择。浏览器登录优先用官方桌面内附的 Codex 登录组件；找不到时可选择自己安装的官方 `codex` 可执行文件。不要选来源不明的程序。登录可取消，超时为 10 分钟；添加账号不会切换现有登录。

浏览器自动登录错账号时，可用「复制登录链接」在无痕窗口打开。该链接有短时登录参数，不要分享。重新登录和编辑 API 只允许非活动档；先切换到其他配置档。API Key 留空表示保留原 Key。macOS 预览版尚未提供付费连接测试按钮。

## 模型目录与可选 Astra 预热

激活 API 档时，同步本机官方 `models_cache.json` 中的模型目录，保留 Astra、Sol、Luna 及后续模型的原有元数据。官方 Codex 必须先取得新缓存；这不是即时联网查询，也不保证服务商提供目录中的模型。自定义模型目录与已选模型保留，官方缓存不改写。

默认不预热。在设置菜单中为当前 API 档开启 Astra 预热并确认费用，再由你本人在 Codex 中审查、信任 hook 并重启。首次发送 Astra 消息时先用 `gpt-5.6-sol` / `low` 发送固定短消息 `Reply only OK.`，成功后官方 Codex 继续原来的 `gpt-6-astra` 请求。不会把原文、附件、工具或项目内容发给 Sol；失败会拦截原消息，可以重试或关闭预热。成功后同账号同会话不再预热，更换 API 地址或 Key 需重新授权。

此功能是实验性的独立服务端预热，可能收费，不保证解决所有服务的首次连接问题，也不共享两个模型的网络连接。只支持默认目录中的文件 API 登录和内置 `openai` 路由；不支持 provider/profile 或环境变量覆盖路由。启用时不会联网，不访问钥匙串来执行 hook，也不绕过 Codex 的 hook 信任要求。

要关闭、卸载或移动应用，请先切回各已启用 API 档并从相同设置入口关闭预热，再重启 Codex。否则用户级 hook 可能继续指向旧应用。设置修改会保留 `hooks.json` 的备份与其他 hook。

## 共享什么

所有账号使用原来的 `~/.codex`。切换器**不移动、不复制、不删除**其中的会话、索引/SQLite 数据库、项目记录、skills、插件、MCP 配置、规则和记忆；磁盘上的项目/工作区也不改动。

账号切换的活动文件写入是 `auth.json` 和 `config.toml` 中允许的根级路由设置、`cli_auth_credentials_store`。其余配置表和文本保留。API 档继续使用内置 `openai` provider 加 `openai_base_url`，与 Windows 版一致。仅在你主动启用/关闭预热时，额外维护用户级 `hooks.json`；授权指纹和成功标记保存在切换器账号库，不保存新明文 Key 或原消息。

**“共享本地内容”不等于跨账号云端同步，也不保证每版官方客户端会展示完全相同的云端入口。** 继续原会话可能把历史发给新的 API 服务商；仅选择可信且允许接收这些内容的服务。不支持热切换或多账号并行使用同一目录。

## 凭据与恢复

- 账号库及恢复日志：`~/Library/Application Support/CodexAccountSwitcher/`，AES-256-GCM 加密，目录 0700、文件 0600。
- 加密密钥：本机登录钥匙串中的 `io.github.sheyinjue-a11y.codex-account-switcher` / `vault-key-v1`，不同步 iCloud。不要删除密钥，否则原账号库无法解密。
- 活动 `~/.codex/auth.json` 仍是官方客户端需要的明文文件。工具副本加密不防御同一用户下的恶意程序。
- 发现 `pending.enc` 时，先退出所有 Codex，再点设置中的「恢复未完成切换」。它恢复认证和路由，不恢复/清空历史。外部修改冲突会停止恢复，保留记录供排查。
- 未导入活动账号时，首次启用会单独提示改用 file 登录；同意后才替换旧文件，原认证文件和配置保留在加密的 `first-login-backup.enc`。官方钥匙串不改动。此备份不用于自动回滚日后正常切换。
- 官方登录在工具创建的临时目录进行，完成/取消后清理。若工具被强制终止，可能留下 `login-<UUID>` 目录及凭据；退出登录组件并确认无任务后，由本人删除明确对应的临时目录。不会自动批量删目录。

首次版本不支持 Windows DPAPI 账号库迁移、自定义 `CODEX_HOME`、自定义 provider、配置 profile 覆盖或企业强制登录设置；遇到不支持的复杂根配置会拒绝修改。普通 MCP、项目、skills 等配置表不受影响。不读写官方钥匙串，不修改企业策略。

更新 ad-hoc 签名程序可能再次触发钥匙串授权提示。请核验新版本来源后，由本人决定是否允许；不要删除旧密钥“解决”授权问题。

## 验证范围

GitHub macOS CI 执行隔离 Swift 测试、双架构构建、签名/包结构检查及演示数据界面渲染。测试覆盖共享文件字节不变、凭据刷新保存、身份漂移、错误回滚、中断恢复、外部修改冲突、进程锁、链接拒绝、加密完整性和 API 输入。

真实浏览器 OAuth、真实 Codex Desktop 的账号切换/历史显示、真实 API 服务、Gatekeeper/钥匙串提示及不同 macOS 版本仍需人工验收。发布时标明实际 CI 结果，不把编译通过当作真机业务验收。

开发：安装 Xcode Command Line Tools 后，在 `macos` 目录运行 `swift test`；仓库根运行 `bash macos/scripts/build.sh`。无第三方 Swift 包依赖。

卸载前先关闭各已启用 API 档的 Astra 预热，再删除应用。共享数据、加密库和钥匙串项不会自动删除；若需清除账号凭据，先确认备份和当前登录。删除不是安全擦除，不保证清除 Time Machine/APFS 快照中的副本。
