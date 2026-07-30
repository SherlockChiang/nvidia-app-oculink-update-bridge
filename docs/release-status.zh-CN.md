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

## 公开发布前仍需

- 购买/配置可信 Authenticode 代码签名证书；
- 在广泛稳定版发布前提供签名的原生 bootstrapper/MSI；首批 prerelease 的 `.cmd`
  入口由 ZIP 来源证明覆盖，提权 EXE/PowerShell 均签名；
- 在干净 Win11 稳定版机器上测试全新安装；
- 测试 Win11 Insider、休眠恢复、断网恢复和系统重启；
- 覆盖多张 NVIDIA 桌面卡、双 NVIDIA GPU 和不同 OCuLink 控制器；
- 用下一次 NVIDIA App 自升级验证 schema-aware repair；
- 完成首次 GitHub 建库、分支保护和 Private vulnerability reporting 设置；
- 决定正式图标和后续版本更新渠道。

仓库已经包含 MIT 许可证、无遥测说明、CI 与强制签名 Release 工作流。当前本地和
CI 产物仍应标记为受控预览版，不能把 `NotSigned` 的 ZIP 描述成适合普通用户公开
下载的正式版本。首个公开安装包应在签名证书配置并完成干净机验收后，以 prerelease
发布。
