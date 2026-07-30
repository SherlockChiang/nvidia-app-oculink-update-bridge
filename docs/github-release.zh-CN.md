# GitHub 发布与签名

## 两类构件

CI 在普通 push 和 pull request 上生成未签名 ZIP，仅供自动化验证和开发测试。它会
在 Actions 中保留 14 天，但不应作为面向普通 Win11 用户的安装包传播。

正式 GitHub Release 只由手动 `Signed release` 工作流创建。该工作流会重新构建、
运行本地自测和 NVIDIA 在线元数据集成测试、签名服务 EXE 及所有 PowerShell 安装
脚本/模块、验证 Authenticode、重建 ZIP、逐文件验证 SHA-256，并生成 GitHub/Sigstore
来源证明，最后才创建 `v<version>` Release。

`.cmd` 只是便捷入口，Windows 不支持为批处理文件添加 Authenticode。它们的完整性由
ZIP 的 GitHub/Sigstore 来源证明和包内 SHA-256 清单覆盖；实际提权安装逻辑所在的
PowerShell 文件则必须全部签名。

## `release-signing` Environment

创建名为 `release-signing` 的 GitHub Environment，设置 required reviewers，并只在
该 Environment 中配置：

- `WINDOWS_SIGNING_CERTIFICATE_BASE64`：PFX 文件的 Base64 内容；
- `WINDOWS_SIGNING_CERTIFICATE_PASSWORD`：PFX 密码。

PFX、密码和私钥不得提交到仓库。工作流只将 PFX 写入 GitHub 托管 runner 的临时
目录，并在签名步骤的 `finally` 中删除；runner 任务结束后也会被销毁。checkout
不会持久化 GitHub 凭据，仓库写 token 只显式交给最后的 `gh release create`。
构建、测试和未签名组包在 Secrets 注入前完成；持有 PFX 的步骤只对固定白名单中的
既有 EXE/PowerShell 文件签名，不执行 `dotnet`、项目程序或安装脚本；离开该步骤后
才重新生成清单和 ZIP。

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

## 首次建库后的 GitHub 设置

- 启用 Private vulnerability reporting；
- 为 `main` 设置 branch protection，要求 `Build, test, and package` 通过；
- 禁止强推和删除 `main`；
- 为 `release-signing` Environment 设置 required reviewers，限制管理员访问并定期
  轮换证书；
- 首个签名包先保持 prerelease，完成干净机验证后再转为正式 Release。
