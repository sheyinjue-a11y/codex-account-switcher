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

### 自动适配官方更新

安装 Node.js 22+ 并在本目录执行 `npm ci` 后，只需开启一次：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Enable-LocalApiFastAutoUpdate.ps1
```

也可指定 `-NodePath` 和 `-ModulePath`（包含 `acorn` 的 node_modules 目录）。
开启时记录这两个本机路径，不需要把 Node 加入桌面进程的 PATH，也不会自动下载或执行网络脚本。
以后从桌面切换器使用 API 账户时，先检查官方版本和副本完整性；需要适配时自动构建、校验并启动。
首次更新后的启动会较慢，后续复用通过验证的副本。个人账户不触发自动适配。

自动流程使用语义匹配，支持已知的 Fast 判断结构及变量、文件名变化。
它无法保证任意未来版本都兼容；遇到未知逻辑会停止修改、记录原因，并通过切换器提示降级到官方版。
相同包与补丁工具的失败只尝试一次，更新官方包、补丁工具或恢复依赖后自动重试；也可再次运行开启脚本手动重试。
诊断位于 `%USERPROFILE%\.codex-api-fast-client\auto-update-status.json`。

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

每次启动检查商店版本，以及副本的 EXE、ASAR、运行库哈希。启用自动适配后，
不一致时先尝试重建；未开启或适配失败时提示并回到官方版。
也可手动运行 `Rebuild-LocalApiFastClient.cmd`。安装器串行构建到临时目录，完整
验证后才原子切换清单；失败保留旧清单，已有未知目录移入 quarantine 留供排查。
中断后已完成的版本可通过其独立清单验证并恢复，失败构建保留供排查。

停用：运行 `Disable-LocalApiFastClient.ps1`，退出 Codex 后重新打开切换器。
它同时关闭自动适配并停用安装清单，保留副本以便检查。不要再运行旧版写入 WindowsApps 的修复脚本。

## 验证

已在商店包 `26.928.3736.0` 上验证安装、实际启动，以及从不带商店包身份的进程
发现并启动副本。用户会话已实际加载副本，并保存 `service_tier = "priority"`。
这不代表所有服务商都会加速；部分转发网关即使加速，响应档位仍可能标为 `default`。

`26.1013.4894.0` 将旧版布尔判断改为 `serviceTierAccess`，并把 Fast/Ultrafast
限制移入共享模块。补丁引擎 v2 会解析模块导入，确认界面与请求使用同一个权限
函数后，仅扩展两处认证列表；保留加载状态和服务端限制，仍兼容旧版结构。
该版本已完成副本构建、隔离配置实际启动，以及从真实打包代码提取的界面和请求
函数行为验证。验证没有发送付费请求，也不代表后续版本自动兼容。

`26.1016.8120.0` 的官方名单增加了 Bedrock，补丁引擎 v3 保留其原有权限行为。
该版本已实际通过自动检测、重建、再次启动复用及隔离进程启动；真实原版与修改版
函数各通过 108 组认证/速度限制组合检查。官方 EXE、ASAR 和运行库哈希未变。

```powershell
npm test
powershell.exe -NoProfile -File .\Test-LocalApiFastClient.ps1
powershell.exe -NoProfile -File .\Test-LocalApiFastAutoUpdate.ps1
powershell.exe -NoProfile -File .\Test-LocalApiFastInstaller.ps1
powershell.exe -NoProfile -File ..\chatgpt-account-switch\Test-PackageLaunch.ps1
```

测试使用隔离文件或模拟启动，不读取凭据，不发送付费请求。
