# Win11 产品化架构

## 设计目标

用户体验应接近普通 Windows 工具：一次安装、开机自动工作、可在“已安装的应用”
卸载、升级 NVIDIA App 后能明确提示修复，不要求用户安装 Node 或手动运行脚本。

## 权限拆分

产品建议拆成三个边界，而不是把所有能力塞进管理员服务：

| 组件 | 运行身份 | 职责 |
|---|---|---|
| `NvidiaAppOculinkShim.exe` | `LocalService` | 只监听 loopback、规范化请求、转发官方元数据、写有限日志 |
| `NvidiaAppOculinkUpdateBridge.exe` | 当前用户；维护时经 UAC 成为管理员 | 显示状态/维护菜单、验证包、建立受保护暂存、触发事务脚本 |
| PowerShell 维护脚本 | 启动器批准后的管理员 | 事务式备份/修改 NVIDIA 配置、注册服务、升级和卸载 |
| 可选托盘状态程序 | 当前用户 | 后续可增加常驻提示；不进入服务权限边界 |

常驻服务不能写自己的程序/config/token，也不能写 NVIDIA 配置。只有 runtime
目录允许 `LocalService` 写日志和 PID。这样即使代理进程被利用，也无法持久化
替换自身或篡改 NVIDIA App。

## 服务生命周期

v4 已直接接入 Windows Service Control Manager：

- 自动启动，失败后由 SCM 做受限次数的重启；
- 以 `NT AUTHORITY\LocalService` 运行；
- 单一可执行文件，不依赖系统 Node；
- SCM stop 会取消监听并删除 PID；
- 配置和二进制放在受 ACL 保护的 ProgramData/Program Files 目录。

迁移器会保留 v3 任务 XML、状态和 helper 备份，短暂停止 v3 后在相同 token/端口
启动 v4；任一步失败都会删除新服务并恢复旧任务。首次安装、v3 迁移、v4 修复和
卸载目前已分别实机验证。

## 签名启动器与一次 UAC

可信正式 ZIP 的统一入口是 x64 NativeAOT `NvidiaAppOculinkUpdateBridge.exe`，不启动
CLR，也不读取相邻 `.exe.config`。PE 的静态依赖加载标志和程序集级 P/Invoke 策略都
限定为 System32，并在进入托管入口后继续收紧 DLL 搜索。PE manifest 固定为
`asInvoker`：检查状态不会提权，安装、修复
和卸载才以 `runas` 重启同一个 EXE。因此正式签名包的 UAC 提示显示项目代码签名
发布者，而不是不可签名的批处理或通用 PowerShell 主机。

启动器从进入 `Main` 起持续持有自身文件的只读租约并记录卷/文件 ID；验签前、UAC
启动前和管理员子进程中都会再次核对同一路径身份。租约禁止写入和删除共享，因此
攻击者不能在验签成功后重命名目录或替换将要提权的 EXE。

管理员子进程不会直接执行用户可写解压目录中的文件。它只把编译期固定白名单复制到
ProgramData 下随机暂存目录，目录 ACL 只允许 Administrator/SYSTEM 写入；复制后再次
检查 reparse point、WinVerifyTrust、同一叶证书、版本、长度和签名维护清单中的
SHA-256，同时对签名链（根证书除外）执行吊销检查。通过后才以绝对 System32 路径
启动 Windows PowerShell，清空继承环境并只重建系统 PATH/PSModulePath 和必需的
Known Folder。无论成功、失败还是 UAC 取消，都返回稳定退出码并清理
暂存目录。

CI/本地未签名构建只允许在明确警告后执行自测和只读状态检查，并拒绝提权维护；正式
Release 门禁不接受未签名模式。

显式 installer-batch preview 是独立的安全降级通道：仅 unsigned prerelease 可在
`installer` 子目录携带固定 6 个 `.cmd`，由它们直接启动根目录的 PowerShell 维护脚本。
这条路径不具备启动器的同发布者验签、文件租约或受保护暂存保证，UAC 也只显示
Windows PowerShell。批处理和脚本自提权均使用 Known Folder 下的固定 System32
PowerShell，避免当前目录/`PATH` 宿主替换。打包器、签名器和测试器强制它与签名模式
互斥；可信正式包始终排除该目录。

## 用户可见状态

建议只显示四种状态：

- **正常**：服务、loopback 重定向、官方元数据请求均通过；
- **需要修复**：NVIDIA App 更新覆盖了配置，点击后解释并请求一次 UAC；
- **端口冲突**：其他软件占用 `127.0.0.1:80`，列出进程并给出处理建议；
- **官方接口暂不可用**：保留 NVIDIA App 原错误，不自动反复改配置。

日志默认只记录路由、耗时、修改前后的三个分类字段和 HTTP 状态，不记录 token、
cookie、authorization 或完整请求 URL。

当前 ZIP 的图形启动器提供安装/升级、状态、修复和卸载入口；状态脚本仍返回 0/1/2，
启动器将结果和受限诊断显示给用户。正式图形化托盘 UI 仍属于后续体验增强，不影响
后台服务和 NVIDIA App 的自动检查。

## 发布门槛

当前验证状态：

1. 已完成：归一化单元测试覆盖字符串/数字 `iLp`、Win11 build 和非目标路由；
2. 已完成：隔离端口官方推荐、详情、CORS/PNA、恶意 Origin、非法路径测试；
3. 部分完成：独立测试服务的 LocalService 身份、ACL、SCM 启停和强制崩溃自动
   恢复已验证；系统重启、睡眠/网络矩阵待测；
4. 已完成：首次安装、v3 迁移、幂等修复、卸载恢复和失败回滚路径；
5. 部分完成：x64 自包含服务/ZIP、签名图形入口、管理员暂存、验签/时间戳门禁和
   Sigstore 来源证明流程已实现；仍缺可信正式证书与干净机 SmartScreen/UAC 验收；
6. 待完成：多机型、Win11 稳定版/预览版、NVIDIA App 版本矩阵；
7. 已完成：不硬编码最新驱动版本，并从 PnP 动态生成 NVIDIA `dIDa`。

最后一点很重要：v3 把 `610.88` 写成当时的预期值，适合一次调查，不适合长期自动
更新产品。产品测试应接受 NVIDIA 当前返回的合法新版本，而不是在下一版驱动发布后
误报故障。
