using System.Runtime.InteropServices;

namespace NvidiaAppOculinkShim;

internal static class WindowsServiceHost
{
    private const int ServiceWin32OwnProcess = 0x10;
    private const int ServiceStartPending = 0x2;
    private const int ServiceStopPending = 0x3;
    private const int ServiceRunning = 0x4;
    private const int ServiceStopped = 0x1;
    private const int ServiceAcceptStop = 0x1;
    private const int ServiceControlStop = 0x1;
    private static readonly CancellationTokenSource StopSource = new();
    private static ServiceStatusHandle _statusHandle = null!;
    private static readonly ServiceMainDelegate ServiceMainCallback = ServiceMain;
    private static readonly HandlerDelegate HandlerCallback = Handler;
    private static Func<CancellationToken, Action, Task>? _run;
    private static string _serviceName = "NvidiaAppOculinkShim";

    public static int Run(string serviceName, Func<CancellationToken, Action, Task> run)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Windows Service mode requires Windows");
        _serviceName = serviceName;
        _run = run;
        var table = new[]
        {
            new ServiceTableEntry { Name = _serviceName, Callback = ServiceMainCallback },
            new ServiceTableEntry(),
        };
        return StartServiceCtrlDispatcher(table) ? 0 : Marshal.GetLastWin32Error();
    }

    private static void ServiceMain(int argumentCount, IntPtr arguments)
    {
        _statusHandle = RegisterServiceCtrlHandler(_serviceName, HandlerCallback);
        if (_statusHandle.IsInvalid)
            return;
        Report(ServiceStartPending, 0, 10_000);
        try
        {
            _run!(StopSource.Token, () => Report(ServiceRunning, ServiceAcceptStop, 0))
                .GetAwaiter().GetResult();
            Report(ServiceStopped, 0, 0);
        }
        catch
        {
            Report(ServiceStopped, 0, 0, 1);
        }
    }

    private static void Handler(int control)
    {
        if (control != ServiceControlStop)
            return;
        Report(ServiceStopPending, 0, 10_000);
        StopSource.Cancel();
    }

    private static void Report(int state, int accepted, int waitHint, int exitCode = 0)
    {
        var status = new ServiceStatus
        {
            ServiceType = ServiceWin32OwnProcess,
            CurrentState = state,
            ControlsAccepted = accepted,
            Win32ExitCode = exitCode,
            WaitHint = waitHint,
        };
        SetServiceStatus(_statusHandle, ref status);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ServiceTableEntry
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string? Name;
        public ServiceMainDelegate? Callback;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public int ServiceType;
        public int CurrentState;
        public int ControlsAccepted;
        public int Win32ExitCode;
        public int ServiceSpecificExitCode;
        public int CheckPoint;
        public int WaitHint;
    }

    private sealed class ServiceStatusHandle : SafeHandle
    {
        public ServiceStatusHandle() : base(IntPtr.Zero, false) { }
        public override bool IsInvalid => handle == IntPtr.Zero;
        protected override bool ReleaseHandle() => true;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ServiceMainDelegate(int argumentCount, IntPtr arguments);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void HandlerDelegate(int control);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcher(
        [In] ServiceTableEntry[] serviceTable);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ServiceStatusHandle RegisterServiceCtrlHandler(
        string serviceName,
        HandlerDelegate handler);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(
        ServiceStatusHandle serviceStatusHandle,
        ref ServiceStatus serviceStatus);
}
