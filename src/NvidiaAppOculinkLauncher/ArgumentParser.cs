using System;

namespace NvidiaAppOculinkLauncher
{
    internal static class ArgumentParser
    {
        internal static ParsedCommand Parse(string[] args)
        {
            if (args == null || args.Length == 0)
            {
                return new ParsedCommand(CommandKind.Menu, null, null);
            }

            if (args.Length == 1 &&
                string.Equals(args[0], "--self-test", StringComparison.Ordinal))
            {
                return new ParsedCommand(CommandKind.SelfTest, null, null);
            }

            if (args.Length == 1 &&
                string.Equals(args[0], "--verify-package", StringComparison.Ordinal))
            {
                return new ParsedCommand(CommandKind.VerifyPackage, null, null);
            }

            if (args.Length == 2 &&
                string.Equals(args[0], "--action", StringComparison.Ordinal))
            {
                MaintenanceAction action;
                if (TryParseAction(args[1], out action))
                {
                    return new ParsedCommand(CommandKind.PublicAction, action, null);
                }
                return Invalid("Unknown maintenance action: " + args[1]);
            }

            if (args.Length == 2 &&
                string.Equals(args[0], "--elevated-child", StringComparison.Ordinal))
            {
                MaintenanceAction action;
                if (TryParseAction(args[1], out action) && action != MaintenanceAction.Status)
                {
                    return new ParsedCommand(CommandKind.ElevatedChild, action, null);
                }
                return Invalid("The elevated child action must be setup, repair, or uninstall.");
            }

            return Invalid(
                "Usage: NvidiaAppOculinkUpdateBridge.exe " +
                "[--action setup|status|repair|uninstall | --self-test | " +
                "--verify-package]");
        }

        internal static bool TryParseAction(string value, out MaintenanceAction action)
        {
            switch (value)
            {
                case "setup":
                    action = MaintenanceAction.Setup;
                    return true;
                case "status":
                    action = MaintenanceAction.Status;
                    return true;
                case "repair":
                    action = MaintenanceAction.Repair;
                    return true;
                case "uninstall":
                    action = MaintenanceAction.Uninstall;
                    return true;
                default:
                    action = default(MaintenanceAction);
                    return false;
            }
        }

        internal static string ToArgumentValue(MaintenanceAction action)
        {
            switch (action)
            {
                case MaintenanceAction.Setup:
                    return "setup";
                case MaintenanceAction.Status:
                    return "status";
                case MaintenanceAction.Repair:
                    return "repair";
                case MaintenanceAction.Uninstall:
                    return "uninstall";
                default:
                    throw new ArgumentOutOfRangeException(nameof(action));
            }
        }

        private static ParsedCommand Invalid(string error)
        {
            return new ParsedCommand(CommandKind.Invalid, null, error);
        }
    }
}
