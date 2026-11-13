using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DynamicIsland
{
    public class TrackInfo
    {
        public string Title { get; set; }
        public string Artist { get; set; }
        public string Album { get; set; }
        public string SourceAppId { get; set; }
        public byte[] CoverBytes { get; set; }
        public BitmapImage Cover { get; set; }
        public Color? Accent { get; set; }
        public TimeSpan Duration { get; set; }
        public bool IsPlaying { get; set; }

        /// <summary>Где реально играл трек: vk, yandex, youtube, spotify… (null — неизвестно).</summary>
        public string Platform { get; set; }

        public string Key => (Artist ?? "") + "|" + (Title ?? "");

        public string PlatformShort => Platform == null ? "" : Platforms.Short(Platform);

        public bool IsBrowser
        {
            get
            {
                var id = (SourceAppId ?? "").ToLowerInvariant();
                if (id.Contains("music")) return false;
                return id.Contains("chrome") || id.Contains("msedge") || id.Contains("firefox") ||
                       id.Contains("opera") || id.Contains("yandex") || id.Contains("browser") ||
                       id.Contains("brave") || id.Contains("vivaldi") || id.Contains("arc");
            }
        }

        public string BrowserName
        {
            get
            {
                var id = (SourceAppId ?? "").ToLowerInvariant();
                if (id.Contains("chrome")) return "Chrome";
                if (id.Contains("msedge")) return "Edge";
                if (id.Contains("firefox")) return "Firefox";
                if (id.Contains("opera")) return "Opera";
                if (id.Contains("yandex")) return Loc.T("src_yabrowser");
                if (id.Contains("brave")) return "Brave";
                if (id.Contains("vivaldi")) return "Vivaldi";
                return Loc.T("src_browser");
            }
        }

        /// <summary>Подпись источника под названием трека.</summary>
        public string PlatformLabel
        {
            get
            {
                if (Platform == null) return SourceName;
                var name = Platforms.Name(Platform);
                return IsBrowser ? name + " · " + BrowserName : name;
            }
        }

        public string SourceName
        {
            get
            {
                var raw = SourceAppId ?? "";
                var id = raw.ToLowerInvariant();
                if (id.Contains("spotify")) return "Spotify";
                if (id.Contains("yandex") && id.Contains("music")) return Loc.T("src_yamusic");
                if (id.Contains("chrome")) return "Chrome · " + Loc.T("src_web");
                if (id.Contains("msedge")) return "Edge · " + Loc.T("src_web");
                if (id.Contains("firefox")) return "Firefox · " + Loc.T("src_web");
                if (id.Contains("opera")) return "Opera · " + Loc.T("src_web");
                if (id.Contains("yandex")) return Loc.T("src_yabrowser");
                if (id.Contains("telegram")) return "Telegram";
                if (id.Contains("zunemusic")) return Loc.T("src_mediaplayer");
                if (id.Contains("vlc")) return "VLC";
                if (id.Contains("aimp")) return "AIMP";
                if (string.IsNullOrEmpty(raw)) return Loc.T("src_media");
                var name = raw.Split('!')[0];
                try { name = Path.GetFileNameWithoutExtension(name); } catch { }
                return name;
            }
        }
    }

    /// <summary>Музыкальные площадки: названия и ссылки для поиска трека.</summary>
    public static class Platforms
    {
        public static (string Id, string Name)[] All => new[]
        {
            ("vk", Loc.T("plat_vk")),
            ("yandex", Loc.T("plat_yandex")),
            ("youtube", "YouTube"),
            ("ytmusic", "YouTube Music"),
            ("spotify", "Spotify"),
            ("soundcloud", "SoundCloud"),
            ("apple", "Apple Music"),
        };

        public static string Name(string id)
        {
            foreach (var p in All) if (p.Id == id) return p.Name;
            return id ?? "";
        }

        public static string Short(string id) => id switch
        {
            "vk" => "VK",
            "yandex" => Loc.T("plat_yandex_short"),
            "youtube" => "YouTube",
            "ytmusic" => "YT Music",
            "spotify" => "Spotify",
            "soundcloud" => "SoundCloud",
            "apple" => "Apple",
            _ => ""
        };

        public static void Open(string id, TrackInfo t)
        {
            if (t == null) return;
            var q = ((t.Artist ?? "") + " " + (t.Title ?? "")).Trim();
            var e = Uri.EscapeDataString(q);
            string url = id switch
            {
                "vk" => "https://vk.com/audio?q=" + e + "&section=search",
                "yandex" => "https://music.yandex.ru/search?text=" + e,
                "ytmusic" => "https://music.youtube.com/search?q=" + e,
                "spotify" => "spotify:search:" + e,
                "soundcloud" => "https://soundcloud.com/search?q=" + e,
                "apple" => "https://music.apple.com/search?term=" + e,
                _ => "https://www.youtube.com/results?search_query=" + e,
            };

            if (!Start(url) && id == "spotify")
                Start("https://open.spotify.com/search/" + e);
        }

        static bool Start(string url)
        {
            try
            {
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                return true;
            }
            catch (Exception ex)
            {
                Debug.WriteLine(ex);
                return false;
            }
        }
    }

    public static class ColorUtil
    {
        public static bool TryParse(string s, out Color color)
        {
            color = Colors.Black;
            try
            {
                if (string.IsNullOrWhiteSpace(s)) return false;
                s = s.Trim();
                if (!s.StartsWith("#")) s = "#" + s;
                color = (Color)ColorConverter.ConvertFromString(s);
                return true;
            }
            catch { return false; }
        }

        public static Color Parse(string s, Color fallback) => TryParse(s, out var c) ? c : fallback;

        public static double Luminance(Color c) => (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0;

        /// <summary>Смешивание: t = 0 → a, t = 1 → b.</summary>
        public static Color Mix(Color a, Color b, double t)
        {
            t = Math.Max(0, Math.Min(1, t));
            return Color.FromRgb(
                (byte)Math.Round(a.R + (b.R - a.R) * t),
                (byte)Math.Round(a.G + (b.G - a.G) * t),
                (byte)Math.Round(a.B + (b.B - a.B) * t));
        }

        /// <summary>Самая насыщенная (верхняя левая) точка градиента фона.</summary>
        public static Color GradientStart(Color baseColor, Color tint) => Mix(baseColor, tint, 0.45);

        /// <summary>Три точки градиента фона острова — тёмный оттенок цвета трека, переходящий в цвет панели.</summary>
        public static Color[] GradientColors(Color baseColor, Color tint, byte alpha)
        {
            var c = new[]
            {
                GradientStart(baseColor, tint),
                Mix(baseColor, tint, 0.17),
                baseColor
            };
            for (int i = 0; i < c.Length; i++) c[i].A = alpha;
            return c;
        }

        public static LinearGradientBrush MakeGradient(Color[] c)
        {
            var b = new LinearGradientBrush { StartPoint = new System.Windows.Point(0, 0), EndPoint = new System.Windows.Point(1, 1) };
            b.GradientStops.Add(new GradientStop(c[0], 0));
            b.GradientStops.Add(new GradientStop(c[1], 0.55));
            b.GradientStops.Add(new GradientStop(c[2], 1));
            return b;
        }
    }

    public class NotificationItem
    {
        public string AppName { get; set; }
        public string Title { get; set; }
        public string Body { get; set; }
        public byte[] IconBytes { get; set; }
        public bool IsTelegram { get; set; }
        /// <summary>Показывать даже при выключенных фильтрах (системные/тестовые).</summary>
        public bool Force { get; set; }
    }

    public class LyricLine
    {
        public TimeSpan Time { get; set; }
        public string Text { get; set; }
    }
}
