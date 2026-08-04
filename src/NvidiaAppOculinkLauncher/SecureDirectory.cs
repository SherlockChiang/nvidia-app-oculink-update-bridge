using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace NvidiaAppOculinkLauncher
{
    internal static class SecureDirectory
    {
        private const int ErrorAlreadyExists = 183;
        private const uint SddlRevision1 = 1;
        private const string AdministratorOnlySddl =
            "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            internal int Length;
            internal IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            internal bool InheritHandle;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
            string stringSecurityDescriptor,
            uint stringSdRevision,
            out IntPtr securityDescriptor,
            out uint securityDescriptorSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectory(
            string path,
            ref SecurityAttributes securityAttributes);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr memory);

        internal static bool TryCreateAdministratorOnly(string path)
        {
            IntPtr securityDescriptor;
            uint ignoredSize;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                AdministratorOnlySddl,
                SddlRevision1,
                out securityDescriptor,
                out ignoredSize))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try
            {
                var attributes = new SecurityAttributes
                {
                    Length = Marshal.SizeOf<SecurityAttributes>(),
                    SecurityDescriptor = securityDescriptor,
                    InheritHandle = false,
                };
                if (CreateDirectory(path, ref attributes))
                {
                    return true;
                }
                int error = Marshal.GetLastWin32Error();
                if (error == ErrorAlreadyExists)
                {
                    return false;
                }
                throw new Win32Exception(error);
            }
            finally
            {
                LocalFree(securityDescriptor);
            }
        }
    }
}
