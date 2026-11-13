using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace DynamicIsland
{
    /// <summary>
    /// Достаёт настоящую иконку приложения (Telegram, Discord и т.д.) из его .exe.
    /// Центр уведомлений для обычных (не-Store) программ отдаёт серую заглушку,
    /// поэтому ищем exe по AppUserModelId или по запущенному процессу.
    /// </summary>
    public static class AppIconResolver
    {
        static readonly Dictionary<string, byte[]> Cache = new Dictionary<string, byte[]>();
        static readonly object Lock = new object();

        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder sb, ref int size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint flags, IntPtr token, out IntPtr path);

        public static byte[] Resolve(string appName, string aumid)
        {
            var key = Normalize(appName) + "|" + (aumid ?? "");
            lock (Lock)
            {
                if (Cache.TryGetValue(key, out var cached)) return cached;
            }

            byte[] result = null;
            try
            {
                var path = PathFromAumid(aumid) ?? PathFromProcess(appName);
                if (path != null) result = ExtractPng(path, 128);
            }
            catch (Exception ex) { Debug.WriteLine(ex); }

            // кэшируем только удачные попытки — программа может запуститься позже
            if (result != null)
                lock (Lock) Cache[key] = result;
            return result;
        }

        static string Normalize(string s) =>
            Regex.Replace((s ?? "").ToLowerInvariant(), @"[\s\.\-_]", "");

        static string PathFromAumid(string aumid)
        {
            if (string.IsNullOrWhiteSpace(aumid) || aumid.IndexOf(".exe", StringComparison.OrdinalIgnoreCase) < 0) return null;
            var s = aumid;
            var m = Regex.Match(s, @"^\{([0-9A-Fa-f\-]{36})\}\\?(.*)$");
            if (m.Success)
            {
                if (SHGetKnownFolderPath(Guid.Parse(m.Groups[1].Value), 0, IntPtr.Zero, out var p) != 0) return null;
                var root = Marshal.PtrToStringUni(p);
                Marshal.FreeCoTaskMem(p);
                s = Path.Combine(root ?? "", m.Groups[2].Value);
            }
            return File.Exists(s) ? s : null;
        }

        static string PathFromProcess(string appName)
        {
            var norm = Normalize(appName);
            if (norm.Length < 3) return null;

            var withWindow = new List<string>();
            foreach (var p in Process.GetProcesses())
            {
                try
                {
                    var pn = Normalize(p.ProcessName);
                    bool match = pn == norm ||
                                 (pn.Length >= 4 && norm.StartsWith(pn)) ||
                                 (norm.Length >= 4 && pn.StartsWith(norm));
                    if (match)
                    {
                        var path = ImagePath(p.Id);
                        if (path != null) return path;
                    }
                    else if (p.MainWindowHandle != IntPtr.Zero)
                    {
                        var path = ImagePath(p.Id);
                        if (path != null) withWindow.Add(path);
                    }
                }
                catch { }
                finally { p.Dispose(); }
            }

            // запасной вариант: совпадение по «Описанию файла» / названию продукта в exe
            foreach (var path in withWindow)
            {
                try
                {
                    var vi = FileVersionInfo.GetVersionInfo(path);
                    var d = Normalize(vi.FileDescription);
                    var pr = Normalize(vi.ProductName);
                    if ((d.Length >= 4 && (d == norm || norm.StartsWith(d) || d.StartsWith(norm))) ||
                        (pr.Length >= 4 && (pr == norm || norm.StartsWith(pr) || pr.StartsWith(norm))))
                        return path;
                }
                catch { }
            }
            return null;
        }

        static string ImagePath(int pid)
        {
            var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                var sb = new StringBuilder(1024);
                int size = sb.Capacity;
                return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null;
            }
            finally { CloseHandle(h); }
        }

        static byte[] ExtractPng(string path, int size)
        {
            System.Drawing.Icon icon = null;
            try { icon = System.Drawing.Icon.ExtractIcon(path, 0, size); } catch { }
            if (icon == null)
            {
                try { icon = System.Drawing.Icon.ExtractAssociatedIcon(path); } catch { }
            }
            if (icon == null) return null;

            using (icon)
            using (var bmp = icon.ToBitmap())
            using (var ms = new MemoryStream())
            {
                bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                return ms.ToArray();
            }
        }
    }
}
