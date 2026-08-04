using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace NvidiaAppOculinkLauncher
{
    internal static class NativeUi
    {
        private const int SetupButton = 1001;
        private const int StatusButton = 1002;
        private const int RepairButton = 1003;
        private const int UninstallButton = 1004;
        private const int ConfirmButton = 1101;
        private const int CancelButton = 1102;
        private const int OkButton = 1201;

        private const uint TdfAllowDialogCancellation = 0x00000008;
        private const uint TdfUseCommandLinks = 0x00000010;
        private const uint TdfExpandedByDefault = 0x00000080;
        private const uint TdfSizeToContent = 0x01000000;

        private static readonly IntPtr WarningIcon = new IntPtr(-1);
        private static readonly IntPtr ErrorIcon = new IntPtr(-2);
        private static readonly IntPtr InformationIcon = new IntPtr(-3);

        internal static MaintenanceAction? ShowMainMenu()
        {
            int selected = ShowDialog(
                "NVIDIA App OCuLink Update Bridge / 更新桥",
                "NVIDIA App OCuLink Update Bridge\r\nNVIDIA App OCuLink 更新桥",
                "Choose an operation. Administrative changes request one UAC approval.\r\n" +
                    "请选择操作。涉及系统更改时会请求一次 UAC 授权。",
                new[]
                {
                    new DialogButton(
                        SetupButton,
                        "Setup / 安装或升级\nInstall the bridge or upgrade an existing installation. / 安装更新桥或升级现有安装。"),
                    new DialogButton(
                        StatusButton,
                        "Status / 检查状态\nInspect the service and NVIDIA App integration without elevation. / 无需提权即可检查服务和 NVIDIA App 集成。"),
                    new DialogButton(
                        RepairButton,
                        "Repair / 修复\nValidate and repair the installed bridge. / 校验并修复已安装的更新桥。"),
                    new DialogButton(
                        UninstallButton,
                        "Uninstall / 卸载\nRestore NVIDIA App configuration and remove the bridge. / 恢复 NVIDIA App 配置并移除更新桥。"),
                },
                SetupButton,
                InformationIcon,
                TdfUseCommandLinks | TdfAllowDialogCancellation | TdfSizeToContent,
                null,
                "NVIDIA App continues to download and install official NVIDIA driver packages. / " +
                    "NVIDIA App 仍会下载并安装 NVIDIA 官方驱动包。");

            switch (selected)
            {
                case SetupButton:
                    return MaintenanceAction.Setup;
                case StatusButton:
                    return MaintenanceAction.Status;
                case RepairButton:
                    return MaintenanceAction.Repair;
                case UninstallButton:
                    return MaintenanceAction.Uninstall;
                default:
                    return null;
            }
        }

        internal static bool ConfirmUninstall()
        {
            return ShowConfirmation(
                "Confirm uninstall / 确认卸载",
                "Remove NVIDIA App OCuLink Update Bridge? / 是否卸载更新桥？",
                "This restores NVIDIA App configuration and removes the background service.\r\n" +
                    "此操作会恢复 NVIDIA App 配置并移除后台服务。",
                "Uninstall / 卸载");
        }

        internal static bool ConfirmDevelopmentBuild(string message, string title)
        {
            return ShowConfirmation(
                title,
                "Unsigned development build / 未签名的开发构建",
                message,
                "Continue / 继续");
        }

        internal static void ShowInformation(string message, string title)
        {
            ShowMessage(
                title,
                title,
                message,
                InformationIcon,
                false,
                null);
        }

        internal static void ShowError(string message, string title)
        {
            try
            {
                ShowMessage(
                    title,
                    "The launcher could not continue / 启动器无法继续",
                    message,
                    ErrorIcon,
                    true,
                    null);
            }
            catch
            {
                NativeMethods.MessageBox(
                    IntPtr.Zero,
                    message,
                    title,
                    NativeMethods.MessageBoxOk | NativeMethods.MessageBoxIconError);
            }
        }

        internal static void ShowOperationResult(
            MaintenanceAction action,
            OperationResult result,
            string title)
        {
            bool succeeded = result.ExitCode == 0;
            string actionName = GetActionName(action);
            string instruction = succeeded
                ? actionName + " completed / 操作已完成"
                : actionName + " needs attention / 操作需要处理";
            string content = succeeded
                ? "The operation completed successfully. / 操作已成功完成。"
                : "The operation did not complete successfully. Review the details below. / " +
                    "操作未成功完成，请查看下方详细信息。";
            content += "\r\n\r\nExit code / 退出码: " + result.ExitCode;

            ShowMessage(
                title,
                instruction,
                content,
                succeeded ? InformationIcon : WarningIcon,
                !succeeded,
                result.ToDisplayText());
        }

        private static bool ShowConfirmation(
            string title,
            string instruction,
            string content,
            string confirmText)
        {
            int selected = ShowDialog(
                title,
                instruction,
                content,
                new[]
                {
                    new DialogButton(ConfirmButton, confirmText),
                    new DialogButton(CancelButton, "Cancel / 取消"),
                },
                CancelButton,
                WarningIcon,
                TdfAllowDialogCancellation | TdfSizeToContent,
                null,
                null);
            return selected == ConfirmButton;
        }

        private static void ShowMessage(
            string title,
            string instruction,
            string content,
            IntPtr icon,
            bool expandDetails,
            string? details)
        {
            uint flags = TdfAllowDialogCancellation | TdfSizeToContent;
            if (expandDetails && !string.IsNullOrEmpty(details))
            {
                flags |= TdfExpandedByDefault;
            }
            ShowDialog(
                title,
                instruction,
                content,
                new[] { new DialogButton(OkButton, "OK / 确定") },
                OkButton,
                icon,
                flags,
                details,
                null);
        }

        private static int ShowDialog(
            string title,
            string instruction,
            string content,
            IReadOnlyList<DialogButton> buttons,
            int defaultButton,
            IntPtr icon,
            uint flags,
            string? expandedInformation,
            string? footer)
        {
            using (var memory = new DialogMemory())
            {
                var config = new TaskDialogConfig
                {
                    StructSize = (uint)Marshal.SizeOf<TaskDialogConfig>(),
                    WindowTitle = memory.AddString(title),
                    MainIcon = icon,
                    MainInstruction = memory.AddString(instruction),
                    Content = memory.AddString(content),
                    ButtonCount = (uint)buttons.Count,
                    Buttons = memory.AddButtons(buttons),
                    DefaultButton = defaultButton,
                    Flags = flags,
                    ExpandedInformation = memory.AddOptionalString(expandedInformation),
                    ExpandedControlText = string.IsNullOrEmpty(expandedInformation)
                        ? IntPtr.Zero
                        : memory.AddString("Show details / 显示详细信息"),
                    CollapsedControlText = string.IsNullOrEmpty(expandedInformation)
                        ? IntPtr.Zero
                        : memory.AddString("Hide details / 隐藏详细信息"),
                    Footer = memory.AddOptionalString(footer),
                };

                int selectedButton;
                int selectedRadioButton;
                bool verificationChecked;
                int result = NativeMethods.TaskDialogIndirect(
                    ref config,
                    out selectedButton,
                    out selectedRadioButton,
                    out verificationChecked);
                GC.KeepAlive(memory);
                if (result < 0)
                {
                    throw new Win32Exception(
                        result,
                        "TaskDialogIndirect failed with HRESULT 0x" +
                        result.ToString("X8") + ".");
                }
                return selectedButton;
            }
        }

        private static string GetActionName(MaintenanceAction action)
        {
            switch (action)
            {
                case MaintenanceAction.Setup:
                    return "Setup / 安装或升级";
                case MaintenanceAction.Status:
                    return "Status / 检查状态";
                case MaintenanceAction.Repair:
                    return "Repair / 修复";
                case MaintenanceAction.Uninstall:
                    return "Uninstall / 卸载";
                default:
                    throw new ArgumentOutOfRangeException(nameof(action));
            }
        }

        private readonly struct DialogButton
        {
            internal DialogButton(int id, string text)
            {
                Id = id;
                Text = text;
            }

            internal int Id { get; }
            internal string Text { get; }
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct TaskDialogButton
        {
            internal int Id;
            internal IntPtr Text;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct TaskDialogConfig
        {
            internal uint StructSize;
            internal IntPtr Parent;
            internal IntPtr Instance;
            internal uint Flags;
            internal uint CommonButtons;
            internal IntPtr WindowTitle;
            internal IntPtr MainIcon;
            internal IntPtr MainInstruction;
            internal IntPtr Content;
            internal uint ButtonCount;
            internal IntPtr Buttons;
            internal int DefaultButton;
            internal uint RadioButtonCount;
            internal IntPtr RadioButtons;
            internal int DefaultRadioButton;
            internal IntPtr VerificationText;
            internal IntPtr ExpandedInformation;
            internal IntPtr ExpandedControlText;
            internal IntPtr CollapsedControlText;
            internal IntPtr FooterIcon;
            internal IntPtr Footer;
            internal IntPtr Callback;
            internal IntPtr CallbackData;
            internal uint Width;
        }

        private sealed class DialogMemory : IDisposable
        {
            private readonly List<IntPtr> _strings = new List<IntPtr>();
            private IntPtr _buttons;

            internal IntPtr AddString(string value)
            {
                IntPtr pointer = Marshal.StringToCoTaskMemUni(value);
                _strings.Add(pointer);
                return pointer;
            }

            internal IntPtr AddOptionalString(string? value)
            {
                return string.IsNullOrEmpty(value) ? IntPtr.Zero : AddString(value);
            }

            internal IntPtr AddButtons(IReadOnlyList<DialogButton> buttons)
            {
                if (buttons.Count == 0)
                {
                    return IntPtr.Zero;
                }

                int size = Marshal.SizeOf<TaskDialogButton>();
                _buttons = Marshal.AllocHGlobal(checked(size * buttons.Count));
                for (int index = 0; index < buttons.Count; index++)
                {
                    var nativeButton = new TaskDialogButton
                    {
                        Id = buttons[index].Id,
                        Text = AddString(buttons[index].Text),
                    };
                    Marshal.StructureToPtr(
                        nativeButton,
                        IntPtr.Add(_buttons, index * size),
                        false);
                }
                return _buttons;
            }

            public void Dispose()
            {
                if (_buttons != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(_buttons);
                    _buttons = IntPtr.Zero;
                }
                foreach (IntPtr pointer in _strings)
                {
                    Marshal.FreeCoTaskMem(pointer);
                }
                _strings.Clear();
            }
        }
    }
}
