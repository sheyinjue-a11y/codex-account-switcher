# 更新记录

## v0.3.0 — 公开预览版

- Windows / macOS API 档同步本机官方模型缓存，保留 GPT-6 Astra、Sol、Luna 及完整元数据。后续新增、改名和移除的模型随下次激活同步；官方 Codex 需先刷新本地缓存。
- 保留已选模型及用户自定义模型目录；缓存无效时保留上次有效快照。目录更新纳入账号切换的回滚流程。
- 新增默认关闭、按 API 地址与 Key 分别授权的 Astra 首条消息预热。固定 `gpt-5.6-sol` / `low` 短请求成功后，由官方 Codex 发送原来的 Astra 消息；失败拦截，同会话成功后不重复。
- 预热不接收原文、附件、工具或工作区内容，不代替用户批准 hook。HTTPS 校验、响应大小限制、超时和并发去重均有保护。
- 增加两端离线与官方运行时模拟服务测试；Windows ZIP 和 macOS Universal ZIP 由对应提交的 CI 构建。

### 使用与限制

Windows 使用 `Astra-Warmup.cmd`；macOS 使用设置菜单。确认额外请求费用后，在 Codex 中审查并信任 hook，然后重启。卸载或移动程序前，先逐个关闭已启用 API 档的预热。

预热是实验性的独立请求，不共享网络连接，不保证修复服务商的所有首次连接问题。仅支持默认目录、文件 API 登录、内置 `openai` 路由。测试不调用真实付费模型；真实桌面、账号与服务商仍需人工验收。

macOS 13+，Apple Silicon / Intel Universal；仅 ad-hoc 签名，未经 Apple 公证。请核验来源与 SHA256，不要关闭 Gatekeeper。
