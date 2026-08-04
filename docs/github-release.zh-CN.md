# GitHub 发布与签名

## 两类构件

CI 在普通 push 和 pull request 上生成未签名 ZIP，仅供自动化验证和开发测试。它会
在 Actions 中保留 14 天，但不应作为面向普通 Win11 用户的安装包传播。
使用临时自签证书的签名管线全链路自测仅在每周定时任务和手动调度时
运行；这避免 Windows WinTrust 重复校验拖慢每次提交，不改变正式发布的
强制签名门禁。
自测生成随机、短期且根私钥不落盘的测试 CA/叶证书链；根公钥只临时放入
`CurrentUser\CA` 帮助构建链，不写受信任 Root/TrustedPublisher，也不授予系统
信任。测试门禁要求 WinVerifyTrust 的底层错误精确为 `CERT_E_UNTRUSTEDROOT`，并用
.NET `CustomRootTrust` 独立验证代码签名 EKU、叶证书指纹及两层证书链；任何其他
`UnknownError` 均失败。签名后篡改负测还证明哈希不匹配会被拒绝；`finally` 按
指纹移除临时 CA 证书并删除 CER/PFX。正式 Release 不走测试门禁，仍强制
`Valid`、预配置叶证书指纹和时间戳。

可信正式 GitHub Release 只由手动 `Signed release` 工作流创建。该工作流会重新构建、
运行本地自测和 NVIDIA 在线元数据集成测试、签名图形启动器、服务 EXE 及所有
PowerShell 维护文件、验证 Authenticode、重建 ZIP、逐文件验证 SHA-256，并生成
GitHub/Sigstore 来源证明，最后才创建 `v<version>` Release。

可信正式包不包含 Windows 无法 Authenticode 签名的 `.cmd` 入口。启动器、服务和八个
维护脚本/模块先签名；随后生成记录这些“签名后字节”的
`MaintenanceManifest.ps1`，并最后签名该清单。启动器提权后把精确白名单复制到仅
Administrator/SYSTEM 可写的随机暂存目录，再验证 WinVerifyTrust、同一叶证书、
版本、长度和清单 SHA-256，避免从用户可写解压目录直接执行高权限内容。

## `release-signing` Environment

创建名为 `release-signing` 的 GitHub Environment，设置 required reviewers，并只在
该 Environment 中配置：

- `WINDOWS_SIGNING_CERTIFICATE_BASE64`：PFX 文件的 Base64 内容；
- `WINDOWS_SIGNING_CERTIFICATE_PASSWORD`：PFX 密码；
- `WINDOWS_SIGNING_CERTIFICATE_THUMBPRINT`：预期发布叶证书的 40 位 SHA-1
  thumbprint，可包含空格。

PFX、密码和私钥不得提交到仓库。工作流只将 PFX 写入 GitHub 托管 runner 的临时
目录，并在签名步骤的 `finally` 中删除；runner 任务结束后也会被销毁。checkout
不会持久化 GitHub 凭据，仓库写 token 只显式交给最后的 `gh release create`。
构建、测试和未签名组包在 Secrets 注入前完成；持有 PFX 的步骤只对固定白名单中的
既有 EXE/PowerShell 文件签名、计算其 SHA-256、生成并签名维护清单，不执行
`dotnet`、项目程序或安装脚本；离开该步骤后才重新生成包级 SHA 清单和 ZIP。
工作流会在签名前校验 PFX 叶证书指纹，并在签名步骤后以独立清理步骤
删除 runner 上的临时 PFX。

## 发布操作

1. 确保 `main` 上 CI 为绿色，版本已经写入 `CHANGELOG.md`；
2. 在 Actions 中手动运行 `Signed release`；
3. 输入不带 `v` 的 SemVer，例如 `4.0.0`；
4. 初期保持 `prerelease=true`；
5. 下载 Release ZIP 和 `.sha256`，在干净 Win11 机器再次验证安装、状态、更新与卸载。

高级完整性验证可使用：

```powershell
gh attestation verify .\NvidiaAppOculinkUpdateBridge-<version>-win-x64.zip `
  --repo <owner>/<repository>
```

签名证书缺失、在线集成失败、签名状态不是 `Valid`、清单不完整或任一文件哈希不符
时，工作流都会在创建 Release 之前停止。

## 未签名 installer-batch prerelease

维护者可在用户明确接受风险时创建高级用户预览，但必须使用 prerelease，且标题、说明
和 ZIP 内的 `UNSIGNED-PREVIEW.txt` 都要声明没有可信 Authenticode 发布者：

```powershell
$version = '4.1.0-rc.1'
.\build\Publish-Package.ps1 `
  -Version $version -IncludeInstallerBatchFiles
$name = "NvidiaAppOculinkUpdateBridge-$version-win-x64"
.\tests\Test-Package.ps1 `
  -PackagePath ".\artifacts\package\$name" `
  -ArchivePath ".\artifacts\$name.zip" `
  -ExpectInstallerBatchFiles
```

该模式只在 `installer` 子目录加入固定 6 个 `.cmd`，并与 `-RequireSignature`、时间戳
及临时签名测试模式互斥。批处理绕过 NativeAOT 启动器的同发布者验签和安全暂存链，
因此 UAC 只能识别 Windows PowerShell，不能证明脚本来自本项目。它不生成签名发布的
GitHub/Sigstore 来源证明，也不能被改名为 stable 或“受信任安装包”。取得可信证书后
必须回到 `Signed release` 工作流，正式包继续排除 `.cmd`。

批处理和脚本自提权都固定解析 Windows Known Folder 下的 System32 Windows
PowerShell，不允许当前目录或 `PATH` 替换宿主。`Sign-Package.ps1` 会在读取 PFX 前
拒绝 preview marker、`BUILD-INFO` preview 标志或任何 `.cmd`；CI 还覆盖漏传 preview
开关、签名与 preview 混用、额外批处理和逐层移除 marker/批处理后的负向测试。

## 首次建库后的 GitHub 设置

- 启用 Private vulnerability reporting；
- 为 `main` 设置 branch protection，要求 `Build, test, and package` 通过；
- 禁止强推和删除 `main`；
- 为 `release-signing` Environment 设置 required reviewers，限制管理员访问并定期
  轮换证书；
- 首个签名包先保持 prerelease，完成干净机验证后再转为正式 Release。
