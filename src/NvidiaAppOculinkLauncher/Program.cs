using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text;

namespace NvidiaAppOculinkLauncher
{
    internal static class Program
    {
        private const int ErrorInvalidParameter = 87;
        private const int ErrorCancelled = 1223;

        [STAThread]
        private static int Main(string[] args)
        {
            NativeMethods.RestrictDllSearchToSystem32();
            using ExecutableLease executableLease =
                ExecutableLease.Open(GetExecutablePath());
            executableLease.AssertPathIdentity();
            ParsedCommand command = ArgumentParser.Parse(args);
            if (command.Kind != CommandKind.Menu)
            {
                AttachParentConsole();
            }

            try
            {
                switch (command.Kind)
                {
                    case CommandKind.Menu:
                        return RunMenu(executableLease);
                    case CommandKind.PublicAction:
                        return RunPublicAction(
                            command.Action!.Value,
                            executableLease);
                    case CommandKind.ElevatedChild:
                        return RunElevatedChild(
                            command.Action!.Value,
                            executableLease);
                    case CommandKind.SelfTest:
                        return SelfTests.Run();
                    case CommandKind.VerifyPackage:
                        return VerifyPackage(executableLease);
                    default:
                        Console.Error.WriteLine(command.Error);
                        NativeUi.ShowError(
                            command.Error ?? "Invalid command line. / 命令行无效。",
                            "Invalid arguments / 参数无效");
                        return ErrorInvalidParameter;
                }
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception);
                if (command.Kind == CommandKind.Menu ||
                    command.Kind == CommandKind.PublicAction ||
                    command.Kind == CommandKind.ElevatedChild)
                {
                    NativeUi.ShowError(
                        "The launcher could not complete the operation.\r\n" +
                        "启动器未能完成操作。\r\n\r\n" + exception.Message,
                        "NVIDIA App OCuLink Update Bridge");
                }
                return 1;
            }
        }

        private static int RunMenu(ExecutableLease executableLease)
        {
            while (true)
            {
                MaintenanceAction? action = NativeUi.ShowMainMenu();
                if (!action.HasValue)
                {
                    return 0;
                }
                if (action.Value == MaintenanceAction.Uninstall &&
                    !NativeUi.ConfirmUninstall())
                {
                    continue;
                }
                return RunPublicAction(action.Value, executableLease);
            }
        }

        private static int VerifyPackage(ExecutableLease executableLease)
        {
            executableLease.AssertPathIdentity();
            PackageValidation validation = PackageTrust.Validate(
                GetPackageRoot(executableLease.Path),
                executableLease.Path);
            Console.WriteLine(
                "Package verification passed: version=" +
                validation.Manifest.PackageVersion +
                ", trust=" +
                (validation.ProductionTrusted ? "Trusted" : "UnsignedDevelopment"));
            return 0;
        }

        private static int RunPublicAction(
            MaintenanceAction action,
            ExecutableLease executableLease)
        {
            executableLease.AssertPathIdentity();
            string root = GetPackageRoot(executableLease.Path);
            PackageValidation validation = PackageTrust.Validate(
                root,
                executableLease.Path);

            if (action == MaintenanceAction.Status)
            {
                if (!validation.ProductionTrusted && !ConfirmDevelopmentBuild())
                {
                    return ErrorCancelled;
                }
                OperationResult status = PowerShellRunner.Run(
                    MaintenanceAction.Status,
                    root,
                    false);
                ShowOperationResult(MaintenanceAction.Status, status);
                return status.ExitCode;
            }

            if (!validation.ProductionTrusted)
            {
                NativeUi.ShowError(
                    "Unsigned builds may check status but cannot perform privileged " +
                    "maintenance. Use a trusted, signed GitHub Release.\r\n" +
                    "未签名构建可以检查状态，但不能执行提权维护。请使用来自 GitHub " +
                    "Release 的可信签名版本。",
                    "Signed release required / 需要签名版本");
                return 1;
            }

            if (IsAdministrator())
            {
                NativeUi.ShowError(
                    "Start the launcher normally, not with 'Run as administrator'. " +
                    "It will request UAC only for the protected maintenance phase.\r\n" +
                    "请正常启动程序，不要选择“以管理员身份运行”。程序只会在受保护的" +
                    "维护阶段请求 UAC。",
                    "Start normally / 请正常启动");
                return 1;
            }

            return StartElevatedChild(action, executableLease);
        }

        private static int StartElevatedChild(
            MaintenanceAction action,
            ExecutableLease executableLease)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = executableLease.Path,
                Arguments = WindowsCommandLine.JoinArguments(new[]
                {
                    "--elevated-child",
                    ArgumentParser.ToArgumentValue(action),
                }),
                WorkingDirectory = Path.GetDirectoryName(
                    PowerShellRunner.GetPowerShellPath())!,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            };

            try
            {
                executableLease.AssertPathIdentity();
                using (Process process = Process.Start(startInfo) ??
                    throw new InvalidOperationException(
                        "The elevated launcher process did not start."))
                {
                    process.WaitForExit();
                    int exitCode = process.ExitCode;
                    if (exitCode == 0)
                    {
                        TryStartNvidiaApp();
                    }
                    return exitCode;
                }
            }
            catch (Win32Exception exception)
                when (exception.NativeErrorCode == ErrorCancelled)
            {
                NativeUi.ShowInformation(
                    "UAC approval was cancelled; no maintenance action was started.\r\n" +
                    "UAC 授权已取消，未开始任何维护操作。",
                    "Cancelled / 已取消");
                return ErrorCancelled;
            }
        }

        private static int RunElevatedChild(
            MaintenanceAction action,
            ExecutableLease executableLease)
        {
            if (!IsAdministrator())
            {
                throw new UnauthorizedAccessException(
                    "The elevated child requires an administrator token.");
            }

            executableLease.AssertPathIdentity();
            string sourceRoot = GetPackageRoot(executableLease.Path);
            PackageValidation sourceValidation = PackageTrust.Validate(
                sourceRoot,
                executableLease.Path);
            if (!sourceValidation.ProductionTrusted)
            {
                throw new InvalidDataException(
                    "Privileged maintenance requires a trusted signed launcher package.");
            }

            using (StagingArea staging = StagingArea.CreateAndPopulate(
                sourceRoot,
                sourceValidation))
            {
                OperationResult result = PowerShellRunner.Run(
                    action,
                    staging.Path,
                    true);
                ShowOperationResult(action, result);
                return result.ExitCode;
            }
        }

        private static bool ConfirmDevelopmentBuild()
        {
            return NativeUi.ConfirmDevelopmentBuild(
                "UNSIGNED DEVELOPMENT BUILD\r\n" +
                "未签名的开发构建\r\n\r\n" +
                "This launcher has no Authenticode signature. " +
                "The exact maintenance manifest hashes will still be checked, but this mode is " +
                "not suitable for production use.\r\n\r\n" +
                "此启动器没有 Authenticode 签名。程序仍会校验维护清单中的" +
                "精确哈希，但此模式不适合正式使用。\r\n\r\nContinue / 是否继续？",
                "Development build warning / 开发构建警告");
        }

        internal static string GetNvidiaAppPath()
        {
            string programFiles = Environment.GetFolderPath(
                Environment.SpecialFolder.ProgramFiles);
            return Path.Combine(
                programFiles,
                "NVIDIA Corporation",
                "NVIDIA App",
                "CEF",
                "NVIDIA App.exe");
        }

        private static void TryStartNvidiaApp()
        {
            string appPath = GetNvidiaAppPath();
            if (!File.Exists(appPath))
            {
                return;
            }

            try
            {
                using (Process process = Process.Start(new ProcessStartInfo
                {
                    FileName = appPath,
                    WorkingDirectory = Path.GetDirectoryName(appPath)!,
                    UseShellExecute = true,
                }) ?? throw new InvalidOperationException(
                    "NVIDIA App did not create a process."))
                {
                }
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(
                    "Maintenance succeeded, but NVIDIA App did not restart: " +
                    exception.Message);
                NativeUi.ShowInformation(
                    "Maintenance completed, but NVIDIA App could not be reopened " +
                    "automatically. You can open it normally from the Start menu.\r\n" +
                    "维护已完成，但无法自动重新打开 NVIDIA App。您可以从开始菜单正常打开它。",
                    "Open NVIDIA App manually / 请手动打开 NVIDIA App");
            }
        }

        private static void ShowOperationResult(
            MaintenanceAction action,
            OperationResult result)
        {
            string title = ArgumentParser.ToArgumentValue(action) +
                (result.ExitCode == 0 ? " completed / 已完成" : " needs attention / 需要处理");
            NativeUi.ShowOperationResult(action, result, title);
            if (result.StandardOutput.Length > 0)
            {
                Console.Out.Write(result.StandardOutput);
            }
            if (result.StandardError.Length > 0)
            {
                Console.Error.Write(result.StandardError);
            }
        }

        private static string GetPackageRoot(string executablePath)
        {
            string? directory = Path.GetDirectoryName(executablePath);
            if (string.IsNullOrWhiteSpace(directory))
            {
                throw new InvalidDataException("Unable to resolve the launcher package root.");
            }
            return Path.GetFullPath(directory);
        }

        private static string GetExecutablePath()
        {
            string? path = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new InvalidDataException(
                    "Unable to resolve the native launcher executable path.");
            }
            return Path.GetFullPath(path);
        }

        private static bool IsAdministrator()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                var principal = new WindowsPrincipal(identity);
                return principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
        }

        private static void AttachParentConsole()
        {
            try
            {
                if (!NativeMethods.AttachConsole(NativeMethods.AttachParentProcess))
                {
                    return;
                }
                var output = new StreamWriter(
                    Console.OpenStandardOutput(),
                    new UTF8Encoding(false))
                {
                    AutoFlush = true,
                };
                var error = new StreamWriter(
                    Console.OpenStandardError(),
                    new UTF8Encoding(false))
                {
                    AutoFlush = true,
                };
                Console.SetOut(output);
                Console.SetError(error);
            }
            catch
            {
                // GUI operation does not depend on a parent console.
            }
        }
    }
}
