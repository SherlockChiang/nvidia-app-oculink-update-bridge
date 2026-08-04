# 发布状态

## 已有证据

- v3 实机完整验收后事务迁移为 v4；
- v4 以 `LocalService` 运行，旧计划任务已移除；
- 卸载后 `grd`、`crd`、localized GFWSL 地址和原时间戳全部恢复；
- 从“已卸载”状态执行无 Node 首次安装成功；
- 从实际 ZIP 打包目录执行一键 Setup，正确进入修复/升级路径；
- 强制终止服务进程后，SCM 自动以新 PID 恢复；
- SCM 生命周期/恢复测试使用独立服务名和动态端口，结束后确认无测试服务或目录残留；
- NVIDIA 官方推荐、详情、下载域、CORS/PNA 均通过；
- 非 NVIDIA browser Origin 返回 403，非元数据路径返回 404；
- 服务二进制、配置、两份 NVIDIA 原始备份均记录 SHA-256；
- connected NVIDIA GPU 的 `dIDa` 从 PnP Instance ID 动态推导。
- 公开 GitHub 仓库已建立；`main` 要求 CI 和 PR 审批，并禁止强推/删除；
- Private vulnerability reporting、Dependabot 漏洞警报/安全修复、secret
  scanning 和 push protection 均已开启；
- Actions 只允许固定 SHA 的 GitHub 官方 Action，`release-signing` Environment
  只允许 `main` 且需账号审批。
- 公开 ZIP 已改用自包含 x64 NativeAOT 图形启动器统一处理安装/升级、状态、修复和卸载；
  状态不提权，维护动作由同一 EXE 请求一次 UAC；
- 启动器会把 9 个固定维护输入复制到 Administrator/SYSTEM-only 随机暂存目录，
  重新校验签名者、版本、长度和签名维护清单 SHA-256；
- 未签名完整 ZIP（22 个文件）和 11 文件临时 Authenticode 全链路均已通过；脚本、
  启动器和维护清单的逐字节篡改均被拒绝，临时证书/PFX/包无残留。

## 公开发布前仍需

- 购买/配置可信 Authenticode 代码签名证书；
- 在干净 Win11 稳定版机器上验证正式证书的 Publisher、SmartScreen、全新安装和图形
  启动器一次 UAC；
- 后续如需“已安装的应用”入口与无需保留 ZIP 的维护体验，再提供 MSI/MSIX 或注册
  受保护的已安装维护入口；
- 测试 Win11 Insider、休眠恢复、断网恢复和系统重启；
- 覆盖多张 NVIDIA 桌面卡、双 NVIDIA GPU 和不同 OCuLink 控制器；
- 用下一次 NVIDIA App 自升级验证 schema-aware repair；
- 决定正式图标和后续版本更新渠道。

仓库已经包含 MIT 许可证、无遥测说明、CI 与强制签名 Release 工作流。当前本地和
CI 产物仍应标记为受控预览版，不能把 `NotSigned` 的 ZIP 描述成适合普通用户公开
下载的正式版本。首个公开安装包应在签名证书配置并完成干净机验收后，以 prerelease
发布。
