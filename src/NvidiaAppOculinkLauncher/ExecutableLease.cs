using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NvidiaAppOculinkLauncher
{
    internal sealed class ExecutableLease : IDisposable
    {
        private readonly FileStream _stream;
        private readonly FileIdentity _identity;
        private bool _disposed;

        private ExecutableLease(
            string path,
            FileStream stream,
            FileIdentity identity)
        {
            Path = path;
            _stream = stream;
            _identity = identity;
        }

        internal string Path { get; }

        internal static ExecutableLease Open(string path)
        {
            string fullPath = System.IO.Path.GetFullPath(path);
            var stream = OpenReadLease(fullPath);
            try
            {
                return new ExecutableLease(
                    fullPath,
                    stream,
                    GetIdentity(stream.SafeFileHandle));
            }
            catch
            {
                stream.Dispose();
                throw;
            }
        }

        internal void AssertPathIdentity()
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(ExecutableLease));
            }

            using (FileStream current = OpenReadLease(Path))
            {
                if (!_identity.Equals(GetIdentity(current.SafeFileHandle)))
                {
                    throw new InvalidDataException(
                        "The launcher path no longer identifies the running executable lease.");
                }
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _stream.Dispose();
        }

        private static FileStream OpenReadLease(string path)
        {
            return new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.SequentialScan);
        }

        private static FileIdentity GetIdentity(SafeFileHandle handle)
        {
            if (!GetFileInformationByHandleEx(
                handle,
                FileInfoByHandleClass.FileIdInfo,
                out FileIdInformation info,
                (uint)Marshal.SizeOf<FileIdInformation>()))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return new FileIdentity(
                info.VolumeSerialNumber,
                info.FileId.Low,
                info.FileId.High);
        }

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            FileInfoByHandleClass fileInformationClass,
            out FileIdInformation fileInformation,
            uint bufferSize);

        private enum FileInfoByHandleClass
        {
            FileIdInfo = 18,
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileIdInformation
        {
            internal ulong VolumeSerialNumber;
            internal FileId128 FileId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileId128
        {
            internal ulong Low;
            internal ulong High;
        }

        private readonly struct FileIdentity : IEquatable<FileIdentity>
        {
            private readonly ulong _volumeSerialNumber;
            private readonly ulong _fileIdLow;
            private readonly ulong _fileIdHigh;

            internal FileIdentity(
                ulong volumeSerialNumber,
                ulong fileIdLow,
                ulong fileIdHigh)
            {
                _volumeSerialNumber = volumeSerialNumber;
                _fileIdLow = fileIdLow;
                _fileIdHigh = fileIdHigh;
            }

            public bool Equals(FileIdentity other)
            {
                return _volumeSerialNumber == other._volumeSerialNumber &&
                    _fileIdLow == other._fileIdLow &&
                    _fileIdHigh == other._fileIdHigh;
            }

            public override bool Equals(object? value)
            {
                return value is FileIdentity other && Equals(other);
            }

            public override int GetHashCode()
            {
                return HashCode.Combine(
                    _volumeSerialNumber,
                    _fileIdLow,
                    _fileIdHigh);
            }
        }
    }
}
