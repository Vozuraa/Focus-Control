using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

public sealed class FocusSensorSample
{
    public double CpuPercent { get; set; }
    public double RamPercent { get; set; }
    public double RamUsedGiB { get; set; }
    public double RamTotalGiB { get; set; }
    public double GpuPercent { get; set; }
    public double GpuTemperatureC { get; set; }
    public string GpuName { get; set; }
}

public static class FocusSensors
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        public uint Low;
        public uint High;
        public ulong Ticks { get { return ((ulong)High << 32) | Low; } }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NvmlUtilization
    {
        public uint Gpu;
        public uint Memory;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

    [DllImport("nvml.dll", EntryPoint = "nvmlInit_v2", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NvmlInit();

    [DllImport("nvml.dll", EntryPoint = "nvmlShutdown", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NvmlShutdown();

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetHandleByIndex_v2", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NvmlGetDevice(uint index, out IntPtr device);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetUtilizationRates", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NvmlGetUtilization(IntPtr device, out NvmlUtilization utilization);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetTemperature", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NvmlGetTemperature(IntPtr device, uint sensor, out uint temperature);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetName", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private static extern int NvmlGetName(IntPtr device, StringBuilder name, uint length);

    private static ulong lastIdle;
    private static ulong lastKernel;
    private static ulong lastUser;
    private static bool hasCpuSample;
    private static bool nvmlInitialized;
    private static IntPtr nvmlDevice;
    private static string gpuName = "GPU indisponible";

    static FocusSensors()
    {
        try
        {
            if (NvmlInit() == 0)
            {
                nvmlInitialized = true;
                if (NvmlGetDevice(0, out nvmlDevice) == 0)
                {
                    StringBuilder name = new StringBuilder(128);
                    if (NvmlGetName(nvmlDevice, name, (uint)name.Capacity) == 0)
                    {
                        gpuName = name.ToString();
                    }
                    else
                    {
                        gpuName = "NVIDIA GPU";
                    }
                }
            }
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        catch (BadImageFormatException) { }
    }

    public static FocusSensorSample Read()
    {
        FocusSensorSample sample = new FocusSensorSample();
        sample.CpuPercent = -1;
        sample.RamPercent = -1;
        sample.GpuPercent = -1;
        sample.GpuTemperatureC = -1;
        sample.GpuName = gpuName;

        FileTime idle, kernel, user;
        if (GetSystemTimes(out idle, out kernel, out user))
        {
            ulong idleNow = idle.Ticks;
            ulong kernelNow = kernel.Ticks;
            ulong userNow = user.Ticks;
            if (hasCpuSample)
            {
                ulong idleDelta = idleNow - lastIdle;
                ulong totalDelta = (kernelNow - lastKernel) + (userNow - lastUser);
                if (totalDelta > 0)
                {
                    sample.CpuPercent = Math.Max(0, Math.Min(100,
                        100.0 * (totalDelta - Math.Min(idleDelta, totalDelta)) / totalDelta));
                }
            }
            lastIdle = idleNow;
            lastKernel = kernelNow;
            lastUser = userNow;
            hasCpuSample = true;
        }

        MemoryStatus memory = new MemoryStatus();
        memory.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
        if (GlobalMemoryStatusEx(ref memory) && memory.TotalPhysical > 0)
        {
            sample.RamPercent = memory.MemoryLoad;
            sample.RamTotalGiB = memory.TotalPhysical / 1073741824.0;
            sample.RamUsedGiB = (memory.TotalPhysical - memory.AvailablePhysical) / 1073741824.0;
        }

        if (nvmlDevice != IntPtr.Zero)
        {
            try
            {
                NvmlUtilization utilization;
                if (NvmlGetUtilization(nvmlDevice, out utilization) == 0)
                {
                    sample.GpuPercent = Math.Min(100, utilization.Gpu);
                }
                uint temperature;
                if (NvmlGetTemperature(nvmlDevice, 0, out temperature) == 0)
                {
                    sample.GpuTemperatureC = temperature;
                }
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }

        return sample;
    }

    public static void Shutdown()
    {
        if (nvmlInitialized)
        {
            try { NvmlShutdown(); }
            catch { }
            nvmlInitialized = false;
        }
    }
}

public static class FocusWindows
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr window, int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr window, int index, int value);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

    public static int ForegroundProcessId()
    {
        uint id;
        GetWindowThreadProcessId(GetForegroundWindow(), out id);
        return (int)id;
    }

    public static bool IsAdministrator()
    {
        WindowsPrincipal principal = new WindowsPrincipal(WindowsIdentity.GetCurrent());
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    public static void MakeClickThrough(IntPtr window)
    {
        const int extendedStyleIndex = -20;
        const int transparent = 0x20;
        const int toolWindow = 0x80;
        const int noActivate = 0x08000000;
        int style = GetWindowLong(window, extendedStyleIndex);
        SetWindowLong(window, extendedStyleIndex, style | transparent | toolWindow | noActivate);
        SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, 0x27);
    }
}

public sealed class FocusFpsCapture : IDisposable
{
    private readonly object gate = new object();
    private readonly Queue<long> frames = new Queue<long>();
    private Process process;
    private int targetProcessId;
    private string lastError = "";

    public bool IsRunning
    {
        get
        {
            try { return process != null && !process.HasExited; }
            catch { return false; }
        }
    }

    public string LastError
    {
        get { lock (gate) { return lastError; } }
    }

    public int TargetProcessId
    {
        get { lock (gate) { return targetProcessId; } }
    }

    public void Start(string executable)
    {
        Stop();
        lock (gate) { lastError = ""; frames.Clear(); }
        ProcessStartInfo info = new ProcessStartInfo();
        info.FileName = executable;
        info.Arguments = "--output_stdout --no_console_stats --exclude_dropped --session_name FocusControl --stop_existing_session";
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        Process next = new Process();
        next.StartInfo = info;
        next.OutputDataReceived += OnOutput;
        next.ErrorDataReceived += OnError;
        try
        {
            if (!next.Start())
            {
                lock (gate) { lastError = "PresentMon n'a pas pu demarrer."; }
                next.Dispose();
                return;
            }
            process = next;
            next.BeginOutputReadLine();
            next.BeginErrorReadLine();
        }
        catch (Exception error)
        {
            lock (gate) { lastError = error.Message; }
            next.Dispose();
        }
    }

    private void OnOutput(object sender, DataReceivedEventArgs eventArgs)
    {
        string line = eventArgs.Data;
        if (String.IsNullOrEmpty(line)) return;
        int first = line.IndexOf(',');
        if (first < 0) return;
        int second = line.IndexOf(',', first + 1);
        if (second < 0) return;
        int processId;
        if (!Int32.TryParse(line.Substring(first + 1, second - first - 1), out processId)) return;
        lock (gate)
        {
            if (processId != targetProcessId || targetProcessId <= 0) return;
            frames.Enqueue(Stopwatch.GetTimestamp());
            PruneFrames();
        }
    }

    private void OnError(object sender, DataReceivedEventArgs eventArgs)
    {
        if (!String.IsNullOrWhiteSpace(eventArgs.Data))
        {
            lock (gate) { lastError = eventArgs.Data.Trim(); }
        }
    }

    private void PruneFrames()
    {
        long threshold = Stopwatch.GetTimestamp() - Stopwatch.Frequency;
        while (frames.Count > 0 && frames.Peek() < threshold) frames.Dequeue();
    }

    public void SetTargetProcessId(int processId)
    {
        lock (gate)
        {
            if (targetProcessId == processId) return;
            targetProcessId = processId;
            frames.Clear();
        }
    }

    public int GetFps()
    {
        lock (gate)
        {
            if (targetProcessId <= 0) return -1;
            PruneFrames();
            return frames.Count;
        }
    }

    public void Stop()
    {
        Process current = process;
        process = null;
        if (current != null)
        {
            try
            {
                if (!current.HasExited)
                {
                    current.Kill();
                    current.WaitForExit(700);
                }
            }
            catch { }
            current.Dispose();
        }
        lock (gate) { frames.Clear(); targetProcessId = 0; }
    }

    public void Dispose() { Stop(); }
}
