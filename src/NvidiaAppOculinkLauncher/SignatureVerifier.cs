using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

namespace NvidiaAppOculinkLauncher
{
    internal sealed class SignatureResult
    {
        internal SignatureResult(bool trusted, string? signerThumbprint, int winTrustResult)
        {
            Trusted = trusted;
            SignerThumbprint = signerThumbprint;
            WinTrustResult = winTrustResult;
        }

        internal bool Trusted { get; }
        internal string? SignerThumbprint { get; }
        internal int WinTrustResult { get; }
    }

    internal static class SignatureVerifier
    {
        private static readonly Guid GenericVerifyV2 =
            new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        private const uint WtdUiNone = 2;
        private const uint WtdRevokeWholeChain = 1;
        private const uint WtdChoiceFile = 1;
        private const uint WtdStateActionVerify = 1;
        private const uint WtdStateActionClose = 2;
        private const uint WtdRevocationCheckChainExcludeRoot = 0x00000080;

        internal static SignatureResult Verify(string path)
        {
            IntPtr pathPointer = IntPtr.Zero;
            IntPtr fileInfoPointer = IntPtr.Zero;
            var trustData = new NativeMethods.WinTrustData();
            int result = unchecked((int)0x800B0100); // TRUST_E_NOSIGNATURE
            string? thumbprint = null;
            bool stateOpened = false;

            try
            {
                pathPointer = Marshal.StringToCoTaskMemUni(path);
                var fileInfo = new NativeMethods.WinTrustFileInfo
                {
                    StructSize = (uint)Marshal.SizeOf<NativeMethods.WinTrustFileInfo>(),
                    FilePath = pathPointer,
                    FileHandle = IntPtr.Zero,
                    KnownSubject = IntPtr.Zero,
                };
                fileInfoPointer = Marshal.AllocHGlobal(
                    Marshal.SizeOf<NativeMethods.WinTrustFileInfo>());
                Marshal.StructureToPtr(fileInfo, fileInfoPointer, false);

                trustData = new NativeMethods.WinTrustData
                {
                    StructSize = (uint)Marshal.SizeOf<NativeMethods.WinTrustData>(),
                    PolicyCallbackData = IntPtr.Zero,
                    SipClientData = IntPtr.Zero,
                    UiChoice = WtdUiNone,
                    RevocationChecks = WtdRevokeWholeChain,
                    UnionChoice = WtdChoiceFile,
                    FileInfo = fileInfoPointer,
                    StateAction = WtdStateActionVerify,
                    StateData = IntPtr.Zero,
                    UrlReference = IntPtr.Zero,
                    ProviderFlags = WtdRevocationCheckChainExcludeRoot,
                    UiContext = 0,
                    SignatureSettings = IntPtr.Zero,
                };

                Guid action = GenericVerifyV2;
                result = NativeMethods.WinVerifyTrust(
                    IntPtr.Zero,
                    ref action,
                    ref trustData);
                stateOpened = trustData.StateData != IntPtr.Zero;
                thumbprint = TryGetSignerThumbprint(trustData.StateData);
            }
            catch
            {
                result = unchecked((int)0x80004005); // E_FAIL; never downgrade to unsigned.
                thumbprint = null;
            }
            finally
            {
                if (stateOpened)
                {
                    trustData.StateAction = WtdStateActionClose;
                    Guid action = GenericVerifyV2;
                    NativeMethods.WinVerifyTrust(
                        IntPtr.Zero,
                        ref action,
                        ref trustData);
                }
                if (fileInfoPointer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(fileInfoPointer);
                }
                if (pathPointer != IntPtr.Zero)
                {
                    Marshal.FreeCoTaskMem(pathPointer);
                }
            }

            return new SignatureResult(result == 0, thumbprint, result);
        }

        private static string? TryGetSignerThumbprint(IntPtr stateData)
        {
            if (stateData == IntPtr.Zero)
            {
                return null;
            }

            IntPtr providerData = NativeMethods.WTHelperProvDataFromStateData(stateData);
            if (providerData == IntPtr.Zero)
            {
                return null;
            }
            IntPtr signer = NativeMethods.WTHelperGetProvSignerFromChain(
                providerData, 0, false, 0);
            if (signer == IntPtr.Zero)
            {
                return null;
            }
            IntPtr providerCertificate =
                NativeMethods.WTHelperGetProvCertFromChain(signer, 0);
            if (providerCertificate == IntPtr.Zero)
            {
                return null;
            }

            NativeMethods.CryptProviderCert certificate =
                Marshal.PtrToStructure<NativeMethods.CryptProviderCert>(
                    providerCertificate);
            if (certificate.CertContext == IntPtr.Zero)
            {
                return null;
            }

            using (var signerCertificate = new X509Certificate2(certificate.CertContext))
            {
                return signerCertificate.Thumbprint?.Replace(" ", "").ToUpperInvariant();
            }
        }
    }
}
