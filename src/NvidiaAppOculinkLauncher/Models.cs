using System;

namespace NvidiaAppOculinkLauncher
{
    internal enum MaintenanceAction
    {
        Setup,
        Status,
        Repair,
        Uninstall,
    }

    internal enum CommandKind
    {
        Menu,
        PublicAction,
        ElevatedChild,
        SelfTest,
        VerifyPackage,
        Invalid,
    }

    internal sealed class ParsedCommand
    {
        internal ParsedCommand(CommandKind kind, MaintenanceAction? action, string? error)
        {
            Kind = kind;
            Action = action;
            Error = error;
        }

        internal CommandKind Kind { get; }
        internal MaintenanceAction? Action { get; }
        internal string? Error { get; }
    }

    internal sealed class OperationResult
    {
        internal OperationResult(int exitCode, string standardOutput, string standardError)
        {
            ExitCode = exitCode;
            StandardOutput = standardOutput ?? string.Empty;
            StandardError = standardError ?? string.Empty;
        }

        internal int ExitCode { get; }
        internal string StandardOutput { get; }
        internal string StandardError { get; }

        internal string ToDisplayText()
        {
            string text = (StandardOutput + Environment.NewLine + StandardError).Trim();
            if (text.Length == 0)
            {
                text = ExitCode == 0
                    ? "Operation completed successfully. / 操作已成功完成。"
                    : "The operation did not complete. / 操作未能完成。";
            }

            return text + Environment.NewLine + Environment.NewLine +
                "Exit code / 退出码: " + ExitCode;
        }
    }
}
