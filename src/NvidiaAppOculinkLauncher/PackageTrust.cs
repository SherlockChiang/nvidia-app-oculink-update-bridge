using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;

namespace NvidiaAppOculinkLauncher
{
    internal sealed class PackageValidation
    {
        internal PackageValidation(
            bool productionTrusted,
            string? signerThumbprint,
            MaintenanceManifest manifest)
        {
            ProductionTrusted = productionTrusted;
            SignerThumbprint = signerThumbprint;
            Manifest = manifest;
        }

        internal bool ProductionTrusted { get; }
        internal string? SignerThumbprint { get; }
        internal MaintenanceManifest Manifest { get; }
    }

    internal static class PackageTrust
    {
        internal const string LauncherFileName = "NvidiaAppOculinkUpdateBridge.exe";
        internal const int TrustENoSignature = unchecked((int)0x800B0100);

        internal static PackageValidation Validate(
            string packageRoot,
            string launcherPath,
            string? requiredSignerThumbprint = null)
        {
            string root = Path.GetFullPath(packageRoot).TrimEnd('\\');
            AssertDirectoryIsNotReparsePoint(root);

            string expectedLauncher = CombineBelowRoot(root, LauncherFileName);
            if (!PathsEqual(expectedLauncher, launcherPath))
            {
                throw new InvalidDataException(
                    "The launcher must use its fixed package-root filename.");
            }
            AssertRegularFile(expectedLauncher);
            AssertNoUnexpectedExecutableContent(root);

            string manifestPath = CombineBelowRoot(root, MaintenanceManifest.FileName);
            AssertRegularFile(manifestPath);
            MaintenanceManifest manifest = MaintenanceManifest.Load(manifestPath);

            string? launcherProductVersion =
                FileVersionInfo.GetVersionInfo(expectedLauncher).ProductVersion;
            if (string.IsNullOrWhiteSpace(launcherProductVersion) ||
                !string.Equals(
                    launcherProductVersion,
                    manifest.PackageVersion,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Launcher and maintenance manifest versions do not match.");
            }

            foreach (ManifestEntry entry in manifest.Entries.Values)
            {
                string candidate = CombineBelowRoot(root, entry.RelativePath);
                AssertRegularFile(candidate);
                var info = new FileInfo(candidate);
                if (info.Length != entry.Length)
                {
                    throw new InvalidDataException(
                        "Maintenance file length mismatch: " + entry.RelativePath);
                }
                string actualHash = ComputeSha256(candidate);
                if (!string.Equals(actualHash, entry.Sha256, StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "Maintenance file SHA-256 mismatch: " + entry.RelativePath);
                }
            }

            SignatureResult launcherSignature = SignatureVerifier.Verify(expectedLauncher);
            bool productionTrusted;
            string? signerThumbprint;
            if (requiredSignerThumbprint != null)
            {
                productionTrusted = true;
                signerThumbprint = requiredSignerThumbprint;
                RequireTrustedSigner(
                    launcherSignature,
                    signerThumbprint,
                    LauncherFileName);
            }
            else
            {
                productionTrusted = ClassifyLauncherSignature(
                    launcherSignature,
                    out signerThumbprint);
            }

            if (productionTrusted)
            {
                var signedPaths = new List<string>
                {
                    MaintenanceManifest.FileName,
                };
                signedPaths.AddRange(MaintenanceManifest.RequiredRelativePaths);
                foreach (string relativePath in signedPaths)
                {
                    SignatureResult signature = SignatureVerifier.Verify(
                        CombineBelowRoot(root, relativePath));
                    RequireTrustedSigner(signature, signerThumbprint!, relativePath);
                }
            }

            return new PackageValidation(productionTrusted, signerThumbprint, manifest);
        }

        internal static bool ClassifyLauncherSignature(
            SignatureResult signature,
            out string? signerThumbprint)
        {
            if (signature.Trusted)
            {
                if (string.IsNullOrWhiteSpace(signature.SignerThumbprint))
                {
                    throw new InvalidDataException(
                        "The trusted launcher signature has no signer identity.");
                }
                signerThumbprint = signature.SignerThumbprint;
                return true;
            }
            if (
                signature.WinTrustResult == TrustENoSignature &&
                string.IsNullOrWhiteSpace(signature.SignerThumbprint))
            {
                signerThumbprint = null;
                return false;
            }

            throw new InvalidDataException(
                "The launcher has an invalid or untrusted Authenticode signature. " +
                "WinVerifyTrust=0x" + signature.WinTrustResult.ToString("X8"));
        }

        internal static string CombineBelowRoot(string root, string relativePath)
        {
            string normalized = MaintenanceManifest.NormalizeRelativePath(relativePath);
            string rootFull = Path.GetFullPath(root).TrimEnd('\\');
            string candidate = Path.GetFullPath(Path.Combine(rootFull, normalized));
            string prefix = rootFull + "\\";
            if (!candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Path escapes the package root: " + relativePath);
            }

            string current = rootFull;
            string[] segments = normalized.Split('\\');
            for (int index = 0; index < segments.Length - 1; index++)
            {
                current = Path.Combine(current, segments[index]);
                if (File.Exists(current))
                {
                    throw new InvalidDataException(
                        "A file occupies a package directory path: " + current);
                }
                if (Directory.Exists(current))
                {
                    AssertDirectoryIsNotReparsePoint(current);
                }
            }
            return candidate;
        }

        internal static void AssertRegularFile(string path)
        {
            if (!File.Exists(path))
            {
                throw new FileNotFoundException("Required package file is missing.", path);
            }
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0 ||
                (attributes & FileAttributes.Directory) != 0)
            {
                throw new InvalidDataException("Package file is not a regular file: " + path);
            }
        }

        private static void AssertNoUnexpectedExecutableContent(string root)
        {
            var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                LauncherFileName,
                MaintenanceManifest.FileName,
            };
            foreach (string relativePath in MaintenanceManifest.RequiredRelativePaths)
            {
                if (relativePath.IndexOf('\\') < 0)
                {
                    allowed.Add(relativePath);
                }
            }

            var executableExtensions = new HashSet<string>(
                new[]
                {
                    ".bat", ".cmd", ".com", ".config", ".deps.json", ".dll",
                    ".exe", ".ps1", ".psm1", ".runtimeconfig.json",
                },
                StringComparer.OrdinalIgnoreCase);
            foreach (string file in Directory.GetFiles(
                root,
                "*",
                SearchOption.TopDirectoryOnly))
            {
                string name = Path.GetFileName(file);
                string extension = Path.GetExtension(name);
                if (name.EndsWith(
                    ".runtimeconfig.json",
                    StringComparison.OrdinalIgnoreCase))
                {
                    extension = ".runtimeconfig.json";
                }
                else if (name.EndsWith(
                    ".deps.json",
                    StringComparison.OrdinalIgnoreCase))
                {
                    extension = ".deps.json";
                }
                if (executableExtensions.Contains(extension) &&
                    !allowed.Contains(name))
                {
                    throw new InvalidDataException(
                        "Unexpected executable package content: " + name);
                }
            }
        }

        internal static void AssertDirectoryIsNotReparsePoint(string path)
        {
            var info = new DirectoryInfo(path);
            if (!info.Exists)
            {
                throw new DirectoryNotFoundException("Package directory is missing: " + path);
            }
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidDataException("Package directory is a reparse point: " + path);
            }
        }

        private static string ComputeSha256(string path)
        {
            using (var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 algorithm = SHA256.Create())
            {
                return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "");
            }
        }

        private static void RequireTrustedSigner(
            SignatureResult signature,
            string expectedThumbprint,
            string relativePath)
        {
            if (!signature.Trusted ||
                string.IsNullOrWhiteSpace(signature.SignerThumbprint) ||
                !string.Equals(
                    signature.SignerThumbprint,
                    expectedThumbprint,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    "Required Authenticode trust failed for " + relativePath +
                    ". WinVerifyTrust=0x" + signature.WinTrustResult.ToString("X8"));
            }
        }

        private static bool PathsEqual(string left, string right)
        {
            return string.Equals(
                Path.GetFullPath(left),
                Path.GetFullPath(right),
                StringComparison.OrdinalIgnoreCase);
        }
    }
}
