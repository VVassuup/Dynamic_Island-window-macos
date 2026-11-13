using System;
using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace DynamicIsland
{
    public class AppSettings
    {
        // ---- внешний вид
        public double Scale { get; set; } = 1.0;
        public double TopOffset { get; set; } = 8;
        /// <summary>Цвет фона острова (#RRGGBB).</summary>
        public string IslandColor { get; set; } = "#000000";
        /// <summary>Непрозрачность фона 0.15 … 1.</summary>
        public double IslandOpacity { get; set; } = 1.0;
        /// <summary>Фон острова: solid — сплошной, cover — градиент из цвета трека, custom — градиент своего цвета.</summary>
        public string BackgroundStyle { get; set; } = "solid";
        /// <summary>Цвет для режима «Свой градиент» (#RRGGBB).</summary>
        public string GradientColor { get; set; } = "#FF375F";
        /// <summary>Мягкая подсветка фона цветом обложки.</summary>
        public bool CoverGlow { get; set; } = false;
        /// <summary>Акцент (прогресс, эквалайзер) берётся из обложки.</summary>
        public bool AccentFromCover { get; set; } = true;
        public string AccentColor { get; set; } = "#FFFFFF";
        public bool Shadow { get; set; } = false;
        /// <summary>true — вращающаяся пластинка, false — квадратная обложка как в iOS.</summary>
        public bool VinylCover { get; set; } = false;

        // ---- музыка
        public bool ShowLyrics { get; set; } = true;
        /// <summary>Показывать строку текста песни в свёрнутом острове.</summary>
        public bool ShowVolume { get; set; } = true;
        public bool CompactLyrics { get; set; } = true;
        public bool ShowClock { get; set; } = true;
        /// <summary>auto | vk | yandex | youtube | ytmusic | spotify | soundcloud | apple</summary>
        public string RecentPlatform { get; set; } = "auto";
        /// <summary>music | system — последняя открытая вкладка.</summary>
        public string LastPage { get; set; } = "music";

        // ---- уведомления
        public double NotificationSeconds { get; set; } = 5;
        public bool WindowsNotifications { get; set; } = true;
        public bool TelegramNotifications { get; set; } = true;
        public bool DoNotDisturb { get; set; } = false;

        // ---- система
        public bool HideInFullscreen { get; set; } = true;
        public bool AlwaysOnTop { get; set; } = true;

        // ---- клики сквозь остров
        /// <summary>Клики проходят сквозь остров везде, кроме его кнопок, ползунка, списка треков и уведомлений.</summary>
        public bool ClickThrough { get; set; } = true;

        // «живые» события в острове
        public bool ShowLayoutChange { get; set; } = true;
        public bool ShowCharging { get; set; } = true;
        public bool ShowBluetooth { get; set; } = true;

        // ---- язык
        /// <summary>ru | en. Пусто — взять из установщика или языка Windows.</summary>
        public string Language { get; set; } = "";

        static string FilePath => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "DynamicIsland", "settings.json");

        public static AppSettings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                    return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
            }
            catch { }
            return new AppSettings();
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }
    }

    public static class AutoStart
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ValueName = "DynamicIsland";

        public static bool IsEnabled()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) != null;
            }
            catch { return false; }
        }

        public static void Set(bool enabled)
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey, true) ?? Registry.CurrentUser.CreateSubKey(RunKey);
                if (enabled) key.SetValue(ValueName, "\"" + Environment.ProcessPath + "\"");
                else key.DeleteValue(ValueName, false);
            }
            catch { }
        }
    }
}
