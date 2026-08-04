using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace NvidiaAppOculinkLauncher
{
    internal sealed class StagingArea : IDisposable
    {
        private const string StagingPrefix = "NVIDIAAppOCuLink-Staging-";
        private static readonly TimeSpan StaleDirectoryAge =
            TimeSpan.FromHours(24);
        private readonly string _trustedParent;
        private bool _disposed;

        private StagingArea(string trustedParent, string path)
        {
            _trustedParent = trustedParent;
            Path = path;
        }

        internal string Path { get; }

        internal static StagingArea CreateAndPopulate(
            string sourceRoot,
            PackageValidation sourceValidation)
        {
            string commonData = Environment.GetFolderPath(
                Environment.SpecialFolder.CommonApplicationData);
            AssertTrustedParentChain(commonData);
            CleanupStaleDirectories(commonData, DateTime.UtcNow);
            string? staging = null;
            for (int attempt = 0; attempt < 16; attempt++)
            {
                string candidate = System.IO.Path.Combine(
                    commonData,
                    StagingPrefix + Guid.NewGuid().ToString("N"));
                if (SecureDirectory.TryCreateAdministratorOnly(candidate))
                {
                    staging = candidate;
                    break;
                }
            }
            if (staging == null)
            {
                throw new IOException("Unable to allocate a unique staging directory.");
            }
            AssertProtectedDirectory(staging);

            var area = new StagingArea(commonData, staging);
            try
            {
                area.CopyRegularFile(
                    System.IO.Path.Combine(sourceRoot, PackageTrust.LauncherFileName),
                    PackageTrust.LauncherFileName);
                area.CopyRegularFile(
                    System.IO.Path.Combine(sourceRoot, MaintenanceManifest.FileName),
                    MaintenanceManifest.FileName);
                foreach (string relativePath in MaintenanceManifest.RequiredRelativePaths)
                {
                    area.CopyRegularFile(
                        PackageTrust.CombineBelowRoot(sourceRoot, relativePath),
                        relativePath);
                }

                string stagedLauncher = System.IO.Path.Combine(
                    staging,
                    PackageTrust.LauncherFileName);
                PackageValidation stagedValidation = PackageTrust.Validate(
                    staging,
                    stagedLauncher,
                    sourceValidation.ProductionTrusted
                        ? sourceValidation.SignerThumbprint
                        : null);
                if (stagedValidation.ProductionTrusted !=
                    sourceValidation.ProductionTrusted)
                {
                    throw new InvalidDataException(
                        "Staged package trust mode changed after copying.");
                }

                return area;
            }
            catch
            {
                area.Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;

            try
            {
                string full = System.IO.Path.GetFullPath(Path).TrimEnd('\\');
                string parent = System.IO.Path.GetFullPath(_trustedParent).TrimEnd('\\');
                string prefix = parent + "\\";
                string leaf = System.IO.Path.GetFileName(full);
                if (full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
                    IsStagingLeafName(leaf) &&
                    Directory.Exists(full))
                {
                    AssertProtectedDirectory(full);
                    Directory.Delete(full, true);
                }
            }
            catch
            {
                // A later run may remove an orphaned GUID staging directory.
            }
        }

        internal static bool IsStagingLeafName(string leaf)
        {
            if (!leaf.StartsWith(StagingPrefix, StringComparison.Ordinal))
            {
                return false;
            }

            Guid ignored;
            return Guid.TryParseExact(
                leaf.Substring(StagingPrefix.Length),
                "N",
                out ignored);
        }

        internal static bool IsStaleDirectory(
            DateTime lastWriteTimeUtc,
            DateTime currentTimeUtc)
        {
            return lastWriteTimeUtc <= currentTimeUtc - StaleDirectoryAge;
        }

        private static void CleanupStaleDirectories(
            string trustedParent,
            DateTime currentTimeUtc)
        {
            string parent = System.IO.Path.GetFullPath(trustedParent).TrimEnd('\\');
            string[] candidates;
            try
            {
                candidates = Directory.GetDirectories(
                    parent,
                    StagingPrefix + "*",
                    SearchOption.TopDirectoryOnly);
            }
            catch
            {
                return;
            }

            foreach (string candidate in candidates)
            {
                try
                {
                    string full = System.IO.Path.GetFullPath(candidate).TrimEnd('\\');
                    if (!string.Equals(
                        System.IO.Path.GetDirectoryName(full),
                        parent,
                        StringComparison.OrdinalIgnoreCase) ||
                        !IsStagingLeafName(System.IO.Path.GetFileName(full)))
                    {
                        continue;
                    }

                    PackageTrust.AssertDirectoryIsNotReparsePoint(full);
                    AssertProtectedDirectory(full);
                    var info = new DirectoryInfo(full);
                    if (!IsStaleDirectory(info.LastWriteTimeUtc, currentTimeUtc))
                    {
                        continue;
                    }

                    Directory.Delete(full, true);
                }
                catch
                {
                    // Never delete a candidate whose identity or ACL cannot be proven.
                }
            }
        }

        private void CopyRegularFile(string source, string relativeDestination)
        {
            PackageTrust.AssertRegularFile(source);
            string destination = PackageTrust.CombineBelowRoot(
                Path,
                relativeDestination);
            string? directory = System.IO.Path.GetDirectoryName(destination);
            if (string.IsNullOrEmpty(directory))
            {
                throw new InvalidDataException("Invalid staging destination.");
            }
            if (!Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.Copy(source, destination, false);
            PackageTrust.AssertRegularFile(destination);
        }

        private static void AssertProtectedDirectory(string path)
        {
            PackageTrust.AssertDirectoryIsNotReparsePoint(path);
            DirectorySecurity security = new DirectoryInfo(path).GetAccessControl();
            if (!security.AreAccessRulesProtected)
            {
                throw new InvalidDataException(
                    "Launcher staging directory still inherits permissions.");
            }

            var allowed = new HashSet<string>(StringComparer.Ordinal)
            {
                new SecurityIdentifier(
                    WellKnownSidType.BuiltinAdministratorsSid, null).Value,
                new SecurityIdentifier(
                    WellKnownSidType.LocalSystemSid, null).Value,
            };
            IdentityReference? owner = security.GetOwner(
                typeof(SecurityIdentifier));
            if (owner is not SecurityIdentifier ownerSid ||
                !allowed.Contains(ownerSid.Value))
            {
                throw new InvalidDataException(
                    "Launcher staging directory has an unexpected owner.");
            }

            const FileSystemRights writeRights =
                FileSystemRights.Write |
                FileSystemRights.Modify |
                FileSystemRights.Delete |
                FileSystemRights.ChangePermissions |
                FileSystemRights.TakeOwnership;
            foreach (FileSystemAccessRule rule in security.GetAccessRules(
                true,
                true,
                typeof(SecurityIdentifier)))
            {
                var sid = (SecurityIdentifier)rule.IdentityReference;
                if (rule.AccessControlType == AccessControlType.Allow &&
                    !allowed.Contains(sid.Value) &&
                    (rule.FileSystemRights & writeRights) != 0)
                {
                    throw new InvalidDataException(
                        "Unexpected staging writer: " + sid.Value);
                }
            }
        }

        private static void AssertTrustedParentChain(string path)
        {
            DirectoryInfo? current = new DirectoryInfo(path).Parent;
            PackageTrust.AssertDirectoryIsNotReparsePoint(path);
            while (current != null)
            {
                PackageTrust.AssertDirectoryIsNotReparsePoint(current.FullName);
                current = current.Parent;
            }
        }
    }
}
