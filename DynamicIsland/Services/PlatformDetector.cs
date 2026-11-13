using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace DynamicIsland
{
    /// <summary>
    /// Определяет, где на самом деле играет трек. Для приложений (Spotify, Яндекс Музыка…)
    /// хватает идентификатора медиасессии. Для браузера смотрим заголовки окон:
    /// вкладка VK / YouTube / Яндекс Музыки видна в заголовке окна браузера.
    /// </summary>
    public static class PlatformDetector
    {
        delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);

        static readonly Regex VkWord = new Regex(@"\bvk\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static string Detect(TrackInfo t)
        {
            if (t == null) return null;
            var id = (t.SourceAppId ?? "").ToLowerInvariant();

            if (id.Contains("spotify")) return "spotify";
            if (id.Contains("yandex") && id.Contains("music")) return "yandex";
            if (id.Contains("vkmusic") || id.Contains("vk music") || id.Contains("vk.music") || id.StartsWith("vk")) return "vk";
            if (id.Contains("soundcloud")) return "soundcloud";
            if (id.Contains("applemusic") || id.Contains("apple music")) return "apple";
            if (id.Contains("youtube") && id.Contains("music")) return "ytmusic";
            if (!t.IsBrowser) return null;

            List<(string title, bool browser)> windows;
            try { windows = GetWindows(); }
            catch { return null; }

            // 1) окно, в заголовке которого есть название трека — самый надёжный признак
            var track = (t.Title ?? "").Trim().ToLowerInvariant();
            if (track.Length >= 3)
            {
                foreach (var w in windows)
                {
                    if (!w.title.Contains(track)) continue;
                    var p = FromText(w.title);
                    if (p != null) return p;
                }
            }

            // 2) любое окно браузера с музыкальной вкладкой
            foreach (var w in windows)
            {
                if (!w.browser) continue;
                var p = FromText(w.title);
                if (p != null) return p;
            }
            return null;
        }

        static string FromText(string s)
        {
            if (s.Contains("youtube music")) return "ytmusic";
            if (s.Contains("вконтакте") || s.Contains("vk.com") || s.Contains("vk музыка") || s.Contains("vk music") || VkWord.IsMatch(s)) return "vk";
            if (s.Contains("яндекс музыка") || s.Contains("яндекс.музыка") || s.Contains("yandex music")) return "yandex";
            if (s.Contains("soundcloud")) return "soundcloud";
            if (s.Contains("spotify")) return "spotify";
            if (s.Contains("apple music")) return "apple";
            if (s.Contains("youtube")) return "youtube";
            return null;
        }

        static List<(string title, bool browser)> GetWindows()
        {
            var list = new List<(string, bool)>();
            EnumWindows((h, l) =>
            {
                if (!IsWindowVisible(h)) return true;
                int len = GetWindowTextLength(h);
                if (len <= 0) return true;
                var sb = new StringBuilder(len + 1);
                GetWindowText(h, sb, sb.Capacity);
                var cls = new StringBuilder(128);
                GetClassName(h, cls, 128);
                var c = cls.ToString();
                bool browser = c == "Chrome_WidgetWin_1" || c == "MozillaWindowClass";
                list.Add((sb.ToString().ToLowerInvariant(), browser));
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
