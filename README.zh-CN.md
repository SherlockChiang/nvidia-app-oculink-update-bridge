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

从 GitHub Releases 下载 Win11 x64 ZIP，解压后：

1. 双击 `Setup.cmd` 并批准一次 UAC；
2. 正常使用 NVIDIA App；
3. 双击 `Status.cmd` 可在普通用户权限下检查状态；
4. NVIDIA App 大版本升级后可再次运行 `Setup.cmd` 修复；
5. `Uninstall-NvidiaAppOculinkShim.cmd` 会恢复安装前的 NVIDIA 配置。

`Setup.cmd` 会自动判断首次安装、从 v3 迁移或修复/升级 v4。

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

安装前请确认 Release 资产的 SHA-256 和代码签名。CI 构件与本地构建默认不签名，
仅适合受控测试；`Signed release` 工作流要求服务 EXE 和所有 PowerShell 安装脚本/
模块签名均为 `Valid`，并为 ZIP 与哈希文件生成 GitHub/Sigstore 构建来源证明。

Windows 不支持为 `.cmd` 入口添加 Authenticode。首批 prerelease 依靠 ZIP 来源证明，
并对真正执行提权逻辑的 EXE/PowerShell 全部签名；在提供签名的原生 bootstrapper/MSI
之前，不把它描述成面向大规模普通用户的最终安装器。

本项目采用 [MIT License](LICENSE)。
