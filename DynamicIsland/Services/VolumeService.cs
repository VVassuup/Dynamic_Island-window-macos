using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace DynamicIsland
{
    /// <summary>
    /// Системная громкость Windows (Core Audio, устройство вывода по умолчанию) — аналог VolumeService.swift.
    /// Без сторонних пакетов: чистый COM-interop.
    /// Changed(volume 0…1, muted, available) всегда вызывается в UI-потоке.
    /// </summary>
    public sealed class VolumeService : IDisposable
    {
        public event Action<double, bool, bool> Changed;

        readonly Dispatcher _ui;
        IMMDeviceEnumerator _enumerator;
        IAudioEndpointVolume _endpoint;
        VolumeCallback _volumeCallback;
        DeviceCallback _deviceCallback;
        Guid _ctx = Guid.NewGuid();
        bool _disposed;

        public double Volume { get; private set; } = 0.5;
        public bool Muted { get; private set; }
        public bool Available { get; private set; }

        public VolumeService()
        {
            _ui = Dispatcher.CurrentDispatcher;
        }

        public void Start()
        {
            try
            {
                _enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                _deviceCallback = new DeviceCallback(this);
                _enumerator.RegisterEndpointNotificationCallback(_deviceCallback);
            }
            catch (Exception ex) { Debug.WriteLine(ex); _enumerator = null; }
            Attach();
        }

        /// <summary>Подключиться к текущему устройству вывода по умолчанию.</summary>
        void Attach()
        {
            Detach();
            try
            {
                if (_enumerator != null &&
                    _enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, ERole.Multimedia, out var device) == 0 &&
                    device != null)
                {
                    var iid = typeof(IAudioEndpointVolume).GUID;
                    if (device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out var obj) == 0 && obj is IAudioEndpointVolume ep)
                    {
                        _endpoint = ep;
                        _volumeCallback = new VolumeCallback(this);
                        _endpoint.RegisterControlChangeNotify(_volumeCallback);
                    }
                    Marshal.ReleaseComObject(device);
                }
            }
            catch (Exception ex) { Debug.WriteLine(ex); _endpoint = null; }
            Refresh();
        }

        void Detach()
        {
            if (_endpoint == null) return;
            try
            {
                if (_volumeCallback != null) _endpoint.UnregisterControlChangeNotify(_volumeCallback);
                Marshal.ReleaseComObject(_endpoint);
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
            _endpoint = null;
            _volumeCallback = null;
        }

        /// <summary>Перечитать громкость и сообщить подписчикам.</summary>
        public void Refresh()
        {
            bool available = false;
            double v = Volume;
            bool m = Muted;
            try
            {
                if (_endpoint != null &&
                    _endpoint.GetMasterVolumeLevelScalar(out float level) == 0 &&
                    _endpoint.GetMute(out bool mute) == 0)
                {
                    v = Math.Max(0, Math.Min(1, level));
                    m = mute;
                    available = true;
                }
            }
            catch (Exception ex) { Debug.WriteLine(ex); }

            Volume = v;
            Muted = m;
            Available = available;
            Changed?.Invoke(v, m, available);
        }

        public void SetVolume(double value)
        {
            if (_endpoint == null) return;
            float v = (float)Math.Max(0, Math.Min(1, value));
            try
            {
                _endpoint.SetMasterVolumeLevelScalar(v, ref _ctx);
                // как на Mac: двигаешь громкость — звук включается обратно
                if (v > 0.0005f && Muted) _endpoint.SetMute(false, ref _ctx);
                Volume = v;
                if (v > 0.0005f) Muted = false;
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
        }

        public void SetMuted(bool muted)
        {
            if (_endpoint == null) return;
            try { _endpoint.SetMute(muted, ref _ctx); Muted = muted; }
            catch (Exception ex) { Debug.WriteLine(ex); }
        }

        void PostRefresh()
        {
            if (_disposed) return;
            _ui.BeginInvoke(new Action(() => { if (!_disposed) Refresh(); }));
        }

        void PostReattach()
        {
            if (_disposed) return;
            _ui.BeginInvoke(new Action(() => { if (!_disposed) Attach(); }), DispatcherPriority.Background);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            Detach();
            try
            {
                if (_enumerator != null)
                {
                    if (_deviceCallback != null) _enumerator.UnregisterEndpointNotificationCallback(_deviceCallback);
                    Marshal.ReleaseComObject(_enumerator);
                }
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
            _enumerator = null;
        }

        // ------------------------------------------------------------------ callbacks

        sealed class VolumeCallback : IAudioEndpointVolumeCallback
        {
            readonly VolumeService _owner;
            public VolumeCallback(VolumeService owner) { _owner = owner; }
            public int OnNotify(IntPtr data) { _owner.PostRefresh(); return 0; }
        }

        sealed class DeviceCallback : IMMNotificationClient
        {
            readonly VolumeService _owner;
            public DeviceCallback(VolumeService owner) { _owner = owner; }

            public int OnDefaultDeviceChanged(EDataFlow flow, ERole role, string id)
            {
                if (flow == EDataFlow.Render && role == ERole.Multimedia) _owner.PostReattach();
                return 0;
            }
            public int OnDeviceStateChanged(string id, int state) { _owner.PostReattach(); return 0; }
            public int OnDeviceAdded(string id) => 0;
            public int OnDeviceRemoved(string id) { _owner.PostReattach(); return 0; }
            public int OnPropertyValueChanged(string id, PropertyKey key) => 0;
        }

        // ------------------------------------------------------------------ COM interop

        const int CLSCTX_ALL = 0x17;

        public enum EDataFlow { Render = 0, Capture = 1, All = 2 }
        public enum ERole { Console = 0, Multimedia = 1, Communications = 2 }

        [StructLayout(LayoutKind.Sequential)]
        public struct PropertyKey { public Guid fmtid; public int pid; }

        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        class MMDeviceEnumeratorComObject { }

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IntPtr devices);
            [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
            [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient client);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient client);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
            [PreserveSig] int OpenPropertyStore(int access, out IntPtr properties);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int state);
        }

        [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioEndpointVolume
        {
            [PreserveSig] int RegisterControlChangeNotify(IAudioEndpointVolumeCallback notify);
            [PreserveSig] int UnregisterControlChangeNotify(IAudioEndpointVolumeCallback notify);
            [PreserveSig] int GetChannelCount(out uint count);
            [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid context);
            [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
            [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
            [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
            [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid context);
            [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
            [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
            [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
            [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
            [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        }

        [ComImport, Guid("657804FA-D6AD-4496-8A60-352752AF4F89"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioEndpointVolumeCallback
        {
            [PreserveSig] int OnNotify(IntPtr notifyData);
        }

        [ComImport, Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMNotificationClient
        {
            [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int newState);
            [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDefaultDeviceChanged(EDataFlow flow, ERole role, [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, PropertyKey key);
        }
    }
}
