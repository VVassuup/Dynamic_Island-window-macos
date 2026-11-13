using System;
using System.IO;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace DynamicIsland
{
    public class SystemSnapshot
    {
        public double Cpu;
        public double Ram;
        public ulong RamUsed, RamTotal;
        public double Disk;
        public long DiskFree, DiskTotal;
        public string DiskName = "C:";
        public double Down, Up; // байт/с
        public int Battery = -1;
        public bool Charging;
    }

    /// <summary>Загрузка ЦП, ОЗУ, системного диска, сети и батареи — без сторонних пакетов.</summary>
    public class SystemMonitor
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile,
                         ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

        [DllImport("kernel32.dll")]
        static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

        long _pIdle, _pKernel, _pUser;
        long _pRx, _pTx;
        DateTime _pNet;
        double _cpu;

        public SystemSnapshot Sample()
        {
            var s = new SystemSnapshot();

            // CPU
            try
            {
                if (GetSystemTimes(out var idle, out var kernel, out var user))
                {
                    if (_pKernel != 0)
                    {
                        long dIdle = idle - _pIdle, dK = kernel - _pKernel, dU = user - _pUser;
                        long total = dK + dU; // kernel включает idle
                        if (total > 0) _cpu = Math.Max(0, Math.Min(100, (total - dIdle) * 100.0 / total));
                    }
                    _pIdle = idle; _pKernel = kernel; _pUser = user;
                }
            }
            catch { }
            s.Cpu = _cpu;

            // RAM
            try
            {
                var m = new MEMORYSTATUSEX();
                if (GlobalMemoryStatusEx(m))
                {
                    s.RamTotal = m.ullTotalPhys;
                    s.RamUsed = m.ullTotalPhys - m.ullAvailPhys;
                    s.Ram = m.ullTotalPhys > 0 ? s.RamUsed * 100.0 / m.ullTotalPhys : 0;
                }
            }
            catch { }

            // Системный диск
            try
            {
                var root = Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\";
                var d = new DriveInfo(root);
                s.DiskName = root.TrimEnd('\\');
                s.DiskTotal = d.TotalSize;
                s.DiskFree = d.AvailableFreeSpace;
                s.Disk = d.TotalSize > 0 ? (d.TotalSize - d.TotalFreeSpace) * 100.0 / d.TotalSize : 0;
            }
            catch { }

            // Сеть
            try
            {
                long rx = 0, tx = 0;
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                        ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    try
                    {
                        var st = ni.GetIPStatistics();
                        rx += st.BytesReceived;
                        tx += st.BytesSent;
                    }
                    catch { }
                }
                var now = DateTime.UtcNow;
                if (_pNet != default)
                {
                    double sec = (now - _pNet).TotalSeconds;
                    if (sec > 0.2)
                    {
                        s.Down = Math.Max(0, (rx - _pRx) / sec);
                        s.Up = Math.Max(0, (tx - _pTx) / sec);
                    }
                }
                _pRx = rx; _pTx = tx; _pNet = now;
            }
            catch { }

            // Батарея (ноутбуки)
            try
            {
                var ps = System.Windows.Forms.SystemInformation.PowerStatus;
                var status = ps.BatteryChargeStatus;
                bool none = (status & System.Windows.Forms.BatteryChargeStatus.NoSystemBattery) != 0 ||
                            status == System.Windows.Forms.BatteryChargeStatus.Unknown;
                if (!none && ps.BatteryLifePercent >= 0 && ps.BatteryLifePercent <= 1)
                {
                    s.Battery = (int)Math.Round(ps.BatteryLifePercent * 100);
                    s.Charging = ps.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online;
                }
            }
            catch { }

            return s;
        }
    }
}
