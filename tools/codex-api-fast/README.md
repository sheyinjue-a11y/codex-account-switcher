# Windows API Fast 可选补丁

部分 Codex Windows 版本会对 API Key 登录隐藏 Fast 入口。本工具在用户自己的
官方客户端副本中放开界面和请求的两处认证判断；仍遵守模型档位和
`fast_mode=false` 管理限制。实际加速与计费由 API 服务商决定。

这是可选的本地兼容补丁，默认不安装。不提供 API Key、额度或服务商权限。
仓库和分发包只包含补丁源码，不包含 OpenAI 客户端二进制。

## 安装

需要已安装的官方 Windows 商店版 Codex、Windows PowerShell 5.1，以及 PATH 中
可用的 Node.js 22 或更高版本和 npm。在本目录执行：

```powershell
npm ci
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LocalApiFastClient.ps1
```

Node 不在 PATH 时，可给安装脚本传 `-NodePath <node.exe 的绝对路径>`。
依赖仍需先由 npm 安装。安装无需管理员权限，会额外占用一份客户端的磁盘空间。

安装到 `%USERPROFILE%\.codex-api-fast-client\versions`。这里刻意避开 AppData：
在商店应用内写入 AppData 会被重定向到私有 LocalCache，桌面切换器无法看见。

退出 Codex 后，从本项目的 `Start.cmd` 或桌面切换器选择 API 配置档，
客户端便优先加载通过检查的副本。模型需要声明 Fast 档位支持。
从开始菜单直接打开官方商店应用仍使用原版。

## 改动与限制

- 检查原版启动器的 OpenAI 签名；只修改副本的两处 Fast 认证判断。
- 更新副本启动器内的 ASAR 预期哈希，并调整依赖商店环境的私有程序集声明。
  运行库和 Electron fuse 不变，ASAR 完整性校验保持开启。
- 修改后的启动器不再有有效的 OpenAI Authenticode 签名，属于用户本地修改版。
- 共用原有 `.codex` 登录、会话和项目，显式使用商店版的桌面浏览器数据目录。
  不支持原版和修改版同时使用这些数据。
- 副本没有商店包身份，内置更新器不可用；原版由 Microsoft Store 更新。
  其他依赖包身份的功能未全面验收。

每次启动检查商店版本，以及副本的 EXE、ASAR、运行库哈希。不一致时提示并回到
官方版。官方更新后不会自动重建；运行 `Rebuild-LocalApiFastClient.cmd`。
结构兼容时生成新版本副本，结构变化时拒绝修改，需要适配。无法保证未来每次更新兼容。
已有版本目录不会被覆盖，失败的构建会保留供排查。

停用：运行 `Disable-LocalApiFastClient.ps1`，退出 Codex 后重新打开切换器。
它停用安装清单，保留副本以便检查。不要再运行旧版写入 WindowsApps 的修复脚本。

## 验证

已在商店包 `26.928.3736.0` 上验证安装、实际启动，以及从不带商店包身份的进程
发现并启动副本。用户会话已实际加载副本，并保存 `service_tier = "priority"`。
这不代表所有服务商都会加速；部分转发网关即使加速，响应档位仍可能标为 `default`。

```powershell
npm test
powershell.exe -NoProfile -File .\Test-LocalApiFastClient.ps1
powershell.exe -NoProfile -File ..\chatgpt-account-switch\Test-PackageLaunch.ps1
```

测试使用隔离文件或模拟启动，不读取凭据，不发送付费请求。
