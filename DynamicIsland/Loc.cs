using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using Microsoft.Win32;

namespace DynamicIsland
{
    /// <summary>
    /// Локализация интерфейса.
    /// В XAML строки подключаются как {DynamicResource L_ключ}, в коде — Loc.T("ключ").
    /// Чтобы добавить язык: допишите его в Languages и третий столбец в таблицу S.
    /// </summary>
    public static class Loc
    {
        public static readonly (string Id, string Name)[] Languages =
        {
            ("ru", "Русский"),
            ("en", "English"),
        };

        public static string Lang { get; private set; } = "ru";
        public static CultureInfo Culture { get; private set; } = CultureInfo.GetCultureInfo("ru-RU");
        public static event Action Changed;

        static ResourceDictionary _dict;

        //                                   ru                                              en
        static readonly Dictionary<string, string[]> S = new Dictionary<string, string[]>
        {
            // трей
            ["tray_settings"] = new[] { "Настройки", "Settings" },
            ["tray_dnd"] = new[] { "Не беспокоить", "Do not disturb" },
            ["tray_clickthrough"] = new[] { "Клики сквозь остров", "Click-through island" },
            ["tray_toggle"] = new[] { "Показать / скрыть остров", "Show / hide island" },
            ["tray_test"] = new[] { "Тестовое уведомление", "Test notification" },
            ["tray_language"] = new[] { "Язык", "Language" },
            ["tray_exit"] = new[] { "Выход", "Exit" },

            // уведомления
            ["test_title"] = new[] { "Тестовое уведомление", "Test notification" },
            ["test_body"] = new[] { "Так будут выглядеть сообщения в Dynamic Island 👋", "This is how messages will look in Dynamic Island 👋" },
            ["noaccess_title"] = new[] { "Нет доступа к уведомлениям", "No access to notifications" },
            ["noaccess_body"] = new[] { "Параметры → Конфиденциальность → Уведомления: разрешите доступ приложениям", "Settings → Privacy → Notifications: allow apps to access notifications" },
            ["notif_now"] = new[] { "сейчас", "now" },

            // остров: музыка
            ["tab_music"] = new[] { "Музыка", "Music" },
            ["tab_system"] = new[] { "Система", "System" },
            ["tip_recent"] = new[] { "Недавние треки", "Recent tracks" },
            ["tip_settings"] = new[] { "Настройки", "Settings" },
            ["set_volume"] = new[] { "Ползунок громкости", "Volume slider" },
            ["volume"] = new[] { "Громкость", "Volume" },
            ["recent_title"] = new[] { "Недавние", "Recent" },
            ["recent_rmb"] = new[] { "ПКМ — выбрать сервис", "Right-click — choose service" },
            ["recent_empty"] = new[] { "Здесь появятся прослушанные треки", "Tracks you play will appear here" },
            ["media_nothing"] = new[] { "Ничего не играет", "Nothing playing" },
            ["media_hint"] = new[] { "Включи музыку в любом плеере или в браузере", "Play music in any player or browser" },
            ["media_untitled"] = new[] { "Без названия", "Untitled" },
            ["menu_openin"] = new[] { "Открыть в {0}", "Open in {0}" },
            ["menu_copy"] = new[] { "Скопировать название", "Copy title" },

            // остров: система
            ["sys_title"] = new[] { "Состояние системы", "System status" },
            ["sys_cpu"] = new[] { "ЦП", "CPU" },
            ["sys_ram"] = new[] { "ОЗУ", "RAM" },
            ["sys_disk"] = new[] { "ДИСК", "DISK" },
            ["sys_net"] = new[] { "СЕТЬ", "NETWORK" },
            ["sys_battery"] = new[] { "АККУМУЛЯТОР", "BATTERY" },
            ["sys_threads"] = new[] { "{0} потоков", "{0} threads" },
            ["sys_ramsub"] = new[] { "{0} из {1} ГБ", "{0} of {1} GB" },
            ["sys_disksub"] = new[] { "{0} свободно {1} ГБ", "{0} {1} GB free" },
            ["sys_charging"] = new[] { " · зарядка", " · charging" },
            ["sys_uptime_days"] = new[] { "работает {0} д {1} ч", "up {0} d {1} h" },
            ["sys_uptime_hours"] = new[] { "работает {0} ч {1} мин", "up {0} h {1} min" },
            ["unit_mbs"] = new[] { " МБ/с", " MB/s" },
            ["unit_kbs"] = new[] { " КБ/с", " KB/s" },
            ["unit_sec"] = new[] { " с", " s" },

            // источники и площадки
            ["src_yabrowser"] = new[] { "Яндекс Браузер", "Yandex Browser" },
            ["src_browser"] = new[] { "Браузер", "Browser" },
            ["src_web"] = new[] { "веб", "web" },
            ["src_yamusic"] = new[] { "Яндекс Музыка", "Yandex Music" },
            ["src_mediaplayer"] = new[] { "Медиаплеер", "Media Player" },
            ["src_media"] = new[] { "Медиа", "Media" },
            ["plat_vk"] = new[] { "VK Музыка", "VK Music" },
            ["plat_yandex"] = new[] { "Яндекс Музыка", "Yandex Music" },
            ["plat_yandex_short"] = new[] { "Я.Музыка", "Y.Music" },

            // окно настроек
            ["set_wintitle"] = new[] { "Настройки Dynamic Island", "Dynamic Island Settings" },
            ["set_title"] = new[] { "Настройки", "Settings" },
            ["set_preview"] = new[] { "♪ Превью острова", "♪ Island preview" },
            ["set_appearance"] = new[] { "ВНЕШНИЙ ВИД", "APPEARANCE" },
            ["set_size"] = new[] { "Размер", "Size" },
            ["set_offset"] = new[] { "Отступ сверху", "Top offset" },
            ["set_shadow"] = new[] { "Тень под островом", "Shadow under the island" },
            ["set_vinyl"] = new[] { "Обложка-пластинка", "Vinyl-style cover" },
            ["set_color"] = new[] { "ЦВЕТ И ПРОЗРАЧНОСТЬ", "COLOR & OPACITY" },
            ["set_panelcolor"] = new[] { "Цвет панели", "Panel color" },
            ["set_hex"] = new[] { "Свой цвет (HEX)", "Custom color (HEX)" },
            ["set_opacity"] = new[] { "Непрозрачность", "Opacity" },
            ["set_glow"] = new[] { "Подсветка цветом обложки", "Glow in cover color" },
            ["set_bg"] = new[] { "Фон острова", "Island background" },
            ["set_bg_solid"] = new[] { "Сплошной", "Solid" },
            ["set_bg_cover"] = new[] { "Градиент трека", "Track gradient" },
            ["set_bg_custom"] = new[] { "Свой градиент", "Custom gradient" },
            ["set_gradhex"] = new[] { "Цвет градиента (HEX)", "Gradient color (HEX)" },
            ["set_bghint"] = new[] { "«Градиент трека» берёт цвет из обложки и меняется вместе с песней.", "“Track gradient” takes the color from the album art and changes with every song." },
            ["set_accentcover"] = new[] { "Акцент из обложки", "Accent from cover" },
            ["set_music"] = new[] { "МУЗЫКА", "MUSIC" },
            ["set_lyrics"] = new[] { "Текст песни", "Lyrics" },
            ["set_compactlyrics"] = new[] { "Текст в свёрнутом острове", "Lyrics in compact island" },
            ["set_clock"] = new[] { "Часы в свёрнутом острове", "Clock in compact island" },
            ["set_openrecent"] = new[] { "Прошлые треки открывать в", "Open recent tracks in" },
            ["set_auto"] = new[] { "Где играл", "Where played" },
            ["set_recenthint"] = new[] { "«Где играл» — откроется та площадка, где ты слушал трек. ПКМ по треку в списке — выбрать вручную.", "“Where played” opens the service where you listened to the track. Right-click a track in the list to choose manually." },
            ["set_notifications"] = new[] { "УВЕДОМЛЕНИЯ", "NOTIFICATIONS" },
            ["set_winnotif"] = new[] { "Уведомления Windows", "Windows notifications" },
            ["set_dnd"] = new[] { "Не беспокоить", "Do not disturb" },
            ["set_duration"] = new[] { "Длительность показа", "Display duration" },
            ["set_test"] = new[] { "Отправить тестовое уведомление", "Send test notification" },
            ["set_system"] = new[] { "СИСТЕМА", "SYSTEM" },
            ["set_top"] = new[] { "Всегда поверх окон", "Always on top" },
            ["set_fullscreen"] = new[] { "Прятать в полноэкранных играх и видео", "Hide in fullscreen games and video" },
            ["set_autostart"] = new[] { "Запускать вместе с Windows", "Start with Windows" },
            ["set_clicks"] = new[] { "КЛИКИ СКВОЗЬ ОСТРОВ", "CLICK-THROUGH" },
            ["set_clickthrough"] = new[] { "Пропускать клики сквозь остров", "Let clicks pass through the island" },
            ["set_clickhint"] = new[] { "Клики проходят к окнам под островом везде, кроме кнопок, ползунка, списка треков и уведомлений.", "Clicks go to the windows under the island everywhere except buttons, the slider, the track list and notifications." },
            ["set_events"] = new[] { "СОБЫТИЯ В ОСТРОВЕ", "ISLAND EVENTS" },
            ["set_ev_layout"] = new[] { "Смена раскладки (RU / EN)", "Keyboard layout change (RU / EN)" },
            ["set_ev_power"] = new[] { "Зарядка и низкий заряд", "Charging and low battery" },
            ["set_ev_bt"] = new[] { "Подключение наушников по Bluetooth", "Bluetooth headphones connection" },
            ["ev_layout"] = new[] { "Раскладка", "Layout" },
            ["ev_charging"] = new[] { "Зарядка", "Charging" },
            ["ev_full"] = new[] { "Заряжено", "Fully charged" },
            ["ev_onbattery"] = new[] { "От батареи", "On battery" },
            ["ev_lowbattery"] = new[] { "Низкий заряд", "Low battery" },
            ["ev_bt_connected"] = new[] { "Подключено", "Connected" },
            ["ev_bt_disconnected"] = new[] { "Отключено", "Disconnected" },
            ["set_language"] = new[] { "ЯЗЫК", "LANGUAGE" },
        };

        public static string T(string key)
        {
            if (key == null || !S.TryGetValue(key, out var v)) return key ?? "";
            int i = Index(Lang);
            return i < v.Length && v[i] != null ? v[i] : v[0];
        }

        public static string F(string key, params object[] args)
        {
            try { return string.Format(Culture, T(key), args); }
            catch (FormatException) { return T(key); }
        }

        static int Index(string lang)
        {
            for (int i = 0; i < Languages.Length; i++)
                if (Languages[i].Id == lang) return i;
            return 0;
        }

        /// <summary>Возвращает поддерживаемый код языка или null.</summary>
        public static string Normalize(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return null;
            foreach (var l in Languages)
                if (string.Equals(l.Id, id.Trim(), StringComparison.OrdinalIgnoreCase)) return l.Id;
            return null;
        }

        /// <summary>Переключает язык: обновляет все {DynamicResource L_…} в открытых окнах.</summary>
        public static void Apply(string lang)
        {
            Lang = Normalize(lang) ?? "en";
            Culture = CultureInfo.GetCultureInfo(Lang == "ru" ? "ru-RU" : "en-US");

            var app = Application.Current;
            if (app != null)
            {
                var d = new ResourceDictionary();
                foreach (var kv in S) d["L_" + kv.Key] = T(kv.Key);
                if (_dict != null) app.Resources.MergedDictionaries.Remove(_dict);
                app.Resources.MergedDictionaries.Add(d);
                _dict = d;
            }
            Changed?.Invoke();
        }

        /// <summary>Язык Windows: русский для ru/uk/be/kk, иначе английский.</summary>
        public static string SystemDefault()
        {
            var two = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
            return two == "ru" || two == "uk" || two == "be" || two == "kk" ? "ru" : "en";
        }

        const string InstallerKey = @"Software\Wassup\DynamicIsland";

        /// <summary>
        /// Язык, выбранный в установщике. Значение читается один раз и удаляется,
        /// дальше язык меняется в настройках приложения.
        /// </summary>
        public static string ConsumeInstallerLanguage()
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(InstallerKey, true);
                if (k == null) return null;
                var v = k.GetValue("Language") as string;
                if (v != null) k.DeleteValue("Language", false);
                return Normalize(v);
            }
            catch { return null; }
        }
    }
}
