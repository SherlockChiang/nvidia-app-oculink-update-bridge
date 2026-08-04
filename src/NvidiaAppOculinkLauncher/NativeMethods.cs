using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace NvidiaAppOculinkLauncher
{
    internal static class NativeMethods
    {
        internal const int AttachParentProcess = -1;
        private const uint LoadLibrarySearchSystem32 = 0x00000800;

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetDefaultDllDirectories(uint directoryFlags);

        internal static void RestrictDllSearchToSystem32()
        {
            if (!SetDefaultDllDirectories(LoadLibrarySearchSystem32))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AttachConsole(int processId);

        internal const uint MessageBoxOk = 0x00000000;
        internal const uint MessageBoxIconError = 0x00000010;

        [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
        internal static extern int MessageBox(
            IntPtr windowHandle,
            string text,
            string caption,
            uint type);

        [DllImport("comctl32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        internal static extern int TaskDialogIndirect(
            ref NativeUi.TaskDialogConfig taskConfig,
            out int button,
            out int radioButton,
            [MarshalAs(UnmanagedType.Bool)] out bool verificationFlagChecked);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(
            string commandLine,
            out int argumentCount);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        internal static string[] ParseWindowsCommandLine(string commandLine)
        {
            int count;
            IntPtr arguments = CommandLineToArgvW(commandLine, out count);
            if (arguments == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try
            {
                var result = new List<string>(count);
                for (int index = 0; index < count; index++)
                {
                    IntPtr value = Marshal.ReadIntPtr(
                        arguments,
                        index * IntPtr.Size);
                    result.Add(Marshal.PtrToStringUni(value) ?? string.Empty);
                }
                return result.ToArray();
            }
            finally
            {
                LocalFree(arguments);
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct WinTrustFileInfo
        {
            internal uint StructSize;
            internal IntPtr FilePath;
            internal IntPtr FileHandle;
            internal IntPtr KnownSubject;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct WinTrustData
        {
            internal uint StructSize;
            internal IntPtr PolicyCallbackData;
            internal IntPtr SipClientData;
            internal uint UiChoice;
            internal uint RevocationChecks;
            internal uint UnionChoice;
            internal IntPtr FileInfo;
            internal uint StateAction;
            internal IntPtr StateData;
            internal IntPtr UrlReference;
            internal uint ProviderFlags;
            internal uint UiContext;
            internal IntPtr SignatureSettings;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct CryptProviderCert
        {
            internal uint StructSize;
            internal IntPtr CertContext;
            [MarshalAs(UnmanagedType.Bool)] internal bool Commercial;
            [MarshalAs(UnmanagedType.Bool)] internal bool TrustedRoot;
            [MarshalAs(UnmanagedType.Bool)] internal bool SelfSigned;
            [MarshalAs(UnmanagedType.Bool)] internal bool TestCertificate;
            internal uint RevokedReason;
            internal uint Confidence;
            internal uint Error;
            internal IntPtr TrustListContext;
            [MarshalAs(UnmanagedType.Bool)] internal bool TrustListSignerCertificate;
            internal IntPtr CtlContext;
            internal uint CtlError;
            [MarshalAs(UnmanagedType.Bool)] internal bool Cyclic;
            internal IntPtr ChainElement;
        }

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        internal static extern int WinVerifyTrust(
            IntPtr windowHandle,
            [In] ref Guid actionId,
            ref WinTrustData trustData);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        internal static extern IntPtr WTHelperProvDataFromStateData(IntPtr stateData);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        internal static extern IntPtr WTHelperGetProvSignerFromChain(
            IntPtr providerData,
            uint signerIndex,
            [MarshalAs(UnmanagedType.Bool)] bool counterSigner,
            uint counterSignerIndex);

        [DllImport("wintrust.dll", ExactSpelling = true)]
        internal static extern IntPtr WTHelperGetProvCertFromChain(
            IntPtr providerSigner,
            uint certificateIndex);
    }
}
