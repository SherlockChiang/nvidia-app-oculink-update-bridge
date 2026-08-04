using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace NvidiaAppOculinkLauncher
{
    internal static class PowerShellRunner
    {
        private const int MaximumCapturedCharacters = 64 * 1024;

        internal static string GetPowerShellPath()
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string path = Path.Combine(
                windows,
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!File.Exists(path))
            {
                throw new FileNotFoundException("Windows PowerShell 5.1 was not found.", path);
            }
            return path;
        }

        internal static OperationResult Run(
            MaintenanceAction action,
            string packageRoot,
            bool elevatedPhase)
        {
            string script;
            switch (action)
            {
                case MaintenanceAction.Setup:
                    script = "Setup.ps1";
                    break;
                case MaintenanceAction.Status:
                    script = "Status.ps1";
                    break;
                case MaintenanceAction.Repair:
                    script = "Repair-NvidiaAppOculinkShim.ps1";
                    break;
                case MaintenanceAction.Uninstall:
                    script = "Uninstall-NvidiaAppOculinkShim.ps1";
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(action));
            }

            string scriptPath = PackageTrust.CombineBelowRoot(packageRoot, script);
            var arguments = new List<string>
            {
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                scriptPath,
            };
            if (elevatedPhase)
            {
                arguments.Add("-ElevatedPhase");
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = GetPowerShellPath(),
                Arguments = WindowsCommandLine.JoinArguments(arguments),
                WorkingDirectory = Path.GetFullPath(packageRoot),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            SanitizeEnvironment(startInfo);

            using (Process process = Process.Start(startInfo) ??
                throw new InvalidOperationException("Windows PowerShell did not start."))
            {
                Task<string> output = CaptureAsync(process.StandardOutput);
                Task<string> error = CaptureAsync(process.StandardError);
                process.WaitForExit();
                Task.WaitAll(output, error);
                return new OperationResult(process.ExitCode, output.Result, error.Result);
            }
        }

        private static async Task<string> CaptureAsync(StreamReader reader)
        {
            var captured = new StringBuilder();
            var buffer = new char[4096];
            bool truncated = false;
            while (true)
            {
                int count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }
                int remaining = MaximumCapturedCharacters - captured.Length;
                if (remaining > 0)
                {
                    captured.Append(buffer, 0, Math.Min(count, remaining));
                }
                if (count > remaining)
                {
                    truncated = true;
                }
            }
            if (truncated)
            {
                captured.AppendLine();
                captured.Append("[output truncated / 输出已截断]");
            }
            return captured.ToString();
        }

        internal static void SanitizeEnvironment(ProcessStartInfo startInfo)
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string system32 = Path.Combine(windows, "System32");
            string commonData = Environment.GetFolderPath(
                Environment.SpecialFolder.CommonApplicationData);
            string programFiles = Environment.GetFolderPath(
                Environment.SpecialFolder.ProgramFiles);
            string programFilesX86 = Environment.GetFolderPath(
                Environment.SpecialFolder.ProgramFilesX86);
            string commonProgramFiles = Environment.GetFolderPath(
                Environment.SpecialFolder.CommonProgramFiles);
            string commonProgramFilesX86 = Environment.GetFolderPath(
                Environment.SpecialFolder.CommonProgramFilesX86);
            string userProfile = Environment.GetFolderPath(
                Environment.SpecialFolder.UserProfile);
            string windowsTemp = Path.Combine(windows, "Temp");

            startInfo.EnvironmentVariables.Clear();
            startInfo.EnvironmentVariables["SystemRoot"] = windows;
            startInfo.EnvironmentVariables["WINDIR"] = windows;
            startInfo.EnvironmentVariables["SystemDrive"] =
                Path.GetPathRoot(windows)!.TrimEnd('\\');
            startInfo.EnvironmentVariables["ProgramData"] = commonData;
            startInfo.EnvironmentVariables["ALLUSERSPROFILE"] = commonData;
            startInfo.EnvironmentVariables["ProgramFiles"] = programFiles;
            startInfo.EnvironmentVariables["ProgramFiles(x86)"] = programFilesX86;
            startInfo.EnvironmentVariables["CommonProgramFiles"] = commonProgramFiles;
            startInfo.EnvironmentVariables["CommonProgramFiles(x86)"] =
                commonProgramFilesX86;
            startInfo.EnvironmentVariables["USERPROFILE"] = userProfile;
            startInfo.EnvironmentVariables["TEMP"] = windowsTemp;
            startInfo.EnvironmentVariables["TMP"] = windowsTemp;
            startInfo.EnvironmentVariables["ComSpec"] =
                Path.Combine(system32, "cmd.exe");
            startInfo.EnvironmentVariables["PATHEXT"] =
                ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC";
            startInfo.EnvironmentVariables["PATH"] = string.Join(";", new[]
            {
                system32,
                windows,
                Path.Combine(system32, "Wbem"),
                Path.Combine(system32, "WindowsPowerShell", "v1.0"),
            });
            startInfo.EnvironmentVariables["PSModulePath"] = string.Join(";", new[]
            {
                Path.Combine(programFiles, "WindowsPowerShell", "Modules"),
                Path.Combine(system32, "WindowsPowerShell", "v1.0", "Modules"),
            });
        }
    }
}
