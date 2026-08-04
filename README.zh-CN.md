# NVIDIA App OCuLink 更新桥

[English](README.md) | 简体中文

这是一个非官方 Win11 后台服务，用于修复“笔记本通过 OCuLink 连接 NVIDIA
桌面显卡后，NVIDIA App 无法正常发现驱动更新”的问题。

服务只修正 NVIDIA App 元数据请求中的错误主机分类：

- `iLp=1` 改为 `iLp=0`；
- `osC=10.0.<build>` 归一化为 `10.0`；
- 将真实 Windows build 写入 `osB`。

随后请求通过 HTTPS 转发到 NVIDIA 官方 `gfwsl.geforce.com`。驱动选择、CDN
下载、哈希/签名验证和安装仍全部由 NVIDIA App 完成；本项目不下载或修改驱动包。

## 使用

可信签名版从 GitHub Releases 下载 Win11 x64 ZIP，解压后按以下方式使用。当前
`v4.1.0-rc.1` unsigned prerelease 不适用此维护入口，请直接看下一小节。

1. 双击 `NvidiaAppOculinkUpdateBridge.exe`；
2. 选择“安装或升级”，并批准一次由同一启动器发起的 UAC；
3. 正常使用 NVIDIA App；
4. 随时从启动器执行普通用户权限的“检查状态”；
5. NVIDIA App 大版本升级后再次选择“安装或升级”即可自动修复；“卸载”会恢复安装前
   的 NVIDIA 配置。

启动器会自动判断首次安装、从 v3 迁移或修复/升级 v4。后台服务和 x64 NativeAOT
图形启动器均为自包含程序，不要求用户另装运行库。

### `v4.1.0-rc.1` 未签名批处理预览

该 prerelease 按高级用户预览方式提供，尚无可信 Authenticode 发布者。核对 ZIP 的
SHA-256 并解压后，从普通用户会话双击 `installer\Setup.cmd`；状态、修复和卸载入口也
在同一目录。未签名 NativeAOT 启动器仍会按设计拒绝提权维护，因此该预览必须通过
批处理入口操作。

批处理会启动项目中的未签名 PowerShell 脚本并自行请求 UAC；UAC 显示的是 Windows
PowerShell，而不是本项目的已验证发布者。宿主固定为 System32 Windows PowerShell，
不会从当前目录或 `PATH` 解析。使用前应审查脚本，不要把此预览包描述或转发为受信任
的正式安装包。

## 安全设计

- Windows Service 以 `LocalService` 运行，不使用 SYSTEM；
- 只监听 `127.0.0.1:80`；
- 使用随机 URL token、固定路径白名单、严格 `https://nvfile` Origin、请求大小限制；
- 上游固定为 NVIDIA 官方 HTTPS 域名；
- 程序、配置和原始备份不可由常驻服务写入；
- 安装、修复、卸载均带校验和事务回滚。

端口 80 是 NVIDIA App 当前 WinHTTP URL 解析兼容问题所必需；服务不会监听局域网
地址。详细原理见 [工作流说明](docs/workflow.zh-CN.md)，发布状态见
[发布状态](docs/release-status.zh-CN.md)，维护者发布流程见
[GitHub 发布与签名](docs/github-release.zh-CN.md)。

## 重要说明

本项目与 NVIDIA Corporation 无隶属、背书或合作关系。NVIDIA、GeForce 和
NVIDIA App 是其各自权利人的商标。

安装可信签名 Release 前请同时确认资产的 SHA-256 和代码签名。CI 构件与本地构建
默认不签名，
仅适合自测和只读状态检查；未签名启动器拒绝执行提权维护。`Signed release` 工作流
要求启动器、服务 EXE、维护清单和所有
PowerShell 安装脚本/模块的同一签名均为 `Valid`，并为 ZIP 与哈希文件生成
GitHub/Sigstore 构建来源证明。

启动器以自身签名身份请求 UAC，把固定维护白名单复制到仅 Administrator/SYSTEM 可写
的随机暂存目录，并在运行固定系统 PowerShell 前再次校验 WinVerifyTrust、同一签名者、
版本和受签名清单中的 SHA-256。静态/动态 DLL 加载均限定到 System32；验签后到 UAC
创建管理员子进程期间，启动器还会持有并核对自身文件租约，阻止路径替换。普通包和
签名包不包含旧 `.cmd` 入口；只有显式 unsigned preview 模式会在 `installer` 子目录
加入固定的 6 个批处理，并附带风险说明。

本项目采用 [MIT License](LICENSE)。
