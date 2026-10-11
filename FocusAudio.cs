using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class AudioDeviceEnumeratorClass { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioDeviceEnumerator
{
    [PreserveSig] int EnumAudioEndpoints(int flow, uint states, out IAudioDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IAudioDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IAudioDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioDeviceCollection
{
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int Item(uint index, out IAudioDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioDevice
{
    [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters,
        [MarshalAs(UnmanagedType.IUnknown)] out object result);
    [PreserveSig] int OpenPropertyStore(uint access, out IAudioPropertyStore store);
    [PreserveSig] int GetId(out IntPtr id);
    [PreserveSig] int GetState(out uint state);
}

[StructLayout(LayoutKind.Sequential)]
internal struct AudioPropertyKey
{
    public Guid Format;
    public uint Id;
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct AudioPropertyValue
{
    [FieldOffset(0)] public ushort Type;
    [FieldOffset(8)] public IntPtr Pointer;
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioPropertyStore
{
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out AudioPropertyKey key);
    [PreserveSig] int GetValue(ref AudioPropertyKey key, out AudioPropertyValue value);
    [PreserveSig] int SetValue(ref AudioPropertyKey key, ref AudioPropertyValue value);
    [PreserveSig] int Commit();
}

[ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioMeterInformation
{
    [PreserveSig] int GetPeakValue(out float peak);
    [PreserveSig] int GetChannelsPeakValues(uint count, IntPtr peaks);
    [PreserveSig] int GetMeteringChannelCount(out uint count);
    [PreserveSig] int QueryHardwareSupport(out uint flags);
}

public sealed class FocusAudioDevice
{
    public string Id { get; set; }
    public string Name { get; set; }
    public bool IsDefault { get; set; }
    public override string ToString() { return Name + (IsDefault ? "  ·  par défaut" : ""); }
}

public sealed class FocusMicrophoneMeter : IDisposable
{
    private static readonly Guid FriendlyNameKey = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
    private static readonly Guid MeterGuid = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
    private IAudioDeviceEnumerator enumerator;
    private IAudioDevice device;
    private IAudioMeterInformation meter;

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref AudioPropertyValue value);

    public static FocusAudioDevice[] ListDevices()
    {
        List<FocusAudioDevice> result = new List<FocusAudioDevice>();
        IAudioDeviceEnumerator source = null;
        IAudioDeviceCollection devices = null;
        IAudioDevice defaultDevice = null;
        try
        {
            source = (IAudioDeviceEnumerator)new AudioDeviceEnumeratorClass();
            string defaultId = "";
            if (source.GetDefaultAudioEndpoint(1, 0, out defaultDevice) >= 0 && defaultDevice != null)
                defaultId = DeviceId(defaultDevice);
            if (source.EnumAudioEndpoints(1, 1, out devices) < 0 || devices == null)
                return result.ToArray();
            uint count;
            if (devices.GetCount(out count) < 0) return result.ToArray();
            for (uint index = 0; index < count; index++)
            {
                IAudioDevice current = null;
                try
                {
                    if (devices.Item(index, out current) < 0 || current == null) continue;
                    string id = DeviceId(current);
                    result.Add(new FocusAudioDevice {
                        Id = id,
                        Name = DeviceName(current, (int)index + 1),
                        IsDefault = String.Equals(id, defaultId, StringComparison.OrdinalIgnoreCase)
                    });
                }
                finally { Release(current); }
            }
        }
        catch (COMException) { }
        finally
        {
            Release(defaultDevice);
            Release(devices);
            Release(source);
        }
        return result.ToArray();
    }

    private static string DeviceId(IAudioDevice item)
    {
        IntPtr pointer;
        if (item.GetId(out pointer) < 0 || pointer == IntPtr.Zero) return "";
        try { return Marshal.PtrToStringUni(pointer); }
        finally { Marshal.FreeCoTaskMem(pointer); }
    }

    private static string DeviceName(IAudioDevice item, int number)
    {
        IAudioPropertyStore store = null;
        try
        {
            if (item.OpenPropertyStore(0, out store) < 0 || store == null)
                return "Microphone " + number;
            AudioPropertyKey key = new AudioPropertyKey { Format = FriendlyNameKey, Id = 14 };
            AudioPropertyValue value;
            if (store.GetValue(ref key, out value) < 0) return "Microphone " + number;
            try
            {
                if (value.Type == 31 && value.Pointer != IntPtr.Zero)
                    return Marshal.PtrToStringUni(value.Pointer);
            }
            finally { PropVariantClear(ref value); }
        }
        catch (COMException) { }
        finally { Release(store); }
        return "Microphone " + number;
    }

    public bool Select(string id)
    {
        CloseMeter();
        if (String.IsNullOrEmpty(id)) return false;
        try
        {
            if (enumerator == null)
                enumerator = (IAudioDeviceEnumerator)new AudioDeviceEnumeratorClass();
            if (enumerator.GetDevice(id, out device) < 0 || device == null) return false;
            object value;
            Guid iid = MeterGuid;
            if (device.Activate(ref iid, 23, IntPtr.Zero, out value) < 0 || value == null)
                return false;
            meter = (IAudioMeterInformation)value;
            return true;
        }
        catch (COMException) { CloseMeter(); return false; }
    }

    public double ReadPeak()
    {
        if (meter == null) return -1;
        try
        {
            float peak;
            if (meter.GetPeakValue(out peak) < 0) return -1;
            return Math.Max(0, Math.Min(1, peak));
        }
        catch (COMException) { return -1; }
    }

    private void CloseMeter()
    {
        Release(meter);
        Release(device);
        meter = null;
        device = null;
    }

    public void Dispose()
    {
        CloseMeter();
        Release(enumerator);
        enumerator = null;
    }

    private static void Release(object value)
    {
        if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
    }
}
