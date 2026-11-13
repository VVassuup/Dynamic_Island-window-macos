import Foundation
import Combine

/// Текущий язык как ObservableObject — чтобы SwiftUI перерисовывался при смене языка.
final class LocModel: ObservableObject {
    static let shared = LocModel()
    @Published var lang: String = "ru"
}

/// Локализация интерфейса. В коде — Loc.t("ключ") и Loc.f("ключ", аргументы).
/// Чтобы добавить язык: допишите его в languages и третий столбец в таблицу S.
enum Loc {
    static let languages: [(id: String, name: String)] = [
        ("ru", "Русский"),
        ("en", "English"),
    ]

    static var lang: String { LocModel.shared.lang }

    private static let S: [String: [String]] = [
        // строка меню
        "tray_settings": ["Настройки…", "Settings…"],
        "tray_dnd": ["Не беспокоить", "Do not disturb"],
        "tray_clickthrough": ["Клики сквозь остров", "Click-through island"],
        "tray_toggle": ["Показать / скрыть остров", "Show / hide island"],
        "tray_test": ["Тестовое уведомление", "Test notification"],
        "tray_language": ["Язык", "Language"],
        "tray_exit": ["Выход", "Quit"],
        "tray_about": ["created by @vvassuup", "created by @vvassuup"],
        "tray_telegram": ["t.me/vvassuup", "t.me/vvassuup"],

        // уведомления
        "test_title": ["Тестовое уведомление", "Test notification"],
        "test_body": ["Так будут выглядеть сообщения в Dynamic Island 👋", "This is how messages will look in Dynamic Island 👋"],
        "noaccess_title": ["Нет доступа к уведомлениям", "No access to notifications"],
        "noaccess_body": ["Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску: включите Dynamic Island", "System Settings → Privacy & Security → Full Disk Access: enable Dynamic Island"],
        "notif_now": ["сейчас", "now"],

        // остров: музыка
        "tab_music": ["Музыка", "Music"],
        "tab_system": ["Система", "System"],
        "tip_recent": ["Недавние треки", "Recent tracks"],
        "tip_settings": ["Настройки", "Settings"],
        "recent_title": ["Недавние", "Recent"],
        "recent_rmb": ["ПКМ — выбрать сервис", "Right-click — choose service"],
        "recent_empty": ["Здесь появятся прослушанные треки", "Tracks you play will appear here"],
        "media_nothing": ["Ничего не играет", "Nothing playing"],
        "media_hint": ["Включи музыку в любом плеере или в браузере", "Play music in any player or browser"],
        "media_untitled": ["Без названия", "Untitled"],
        "menu_openin": ["Открыть в {0}", "Open in {0}"],
        "menu_copy": ["Скопировать название", "Copy title"],

        // остров: система
        "sys_title": ["Состояние системы", "System status"],
        "sys_cpu": ["ЦП", "CPU"],
        "sys_ram": ["ОЗУ", "RAM"],
        "sys_disk": ["ДИСК", "DISK"],
        "sys_net": ["СЕТЬ", "NETWORK"],
        "sys_battery": ["АККУМУЛЯТОР", "BATTERY"],
        "sys_threads": ["{0} потоков", "{0} threads"],
        "sys_ramsub": ["{0} из {1} ГБ", "{0} of {1} GB"],
        "sys_disksub": ["{0} свободно {1} ГБ", "{0} {1} GB free"],
        "sys_charging": [" · зарядка", " · charging"],
        "sys_uptime_days": ["работает {0} д {1} ч", "up {0} d {1} h"],
        "sys_uptime_hours": ["работает {0} ч {1} мин", "up {0} h {1} min"],
        "unit_mbs": [" МБ/с", " MB/s"],
        "unit_kbs": [" КБ/с", " KB/s"],
        "unit_sec": [" с", " s"],

        // источники и площадки
        "src_yabrowser": ["Яндекс Браузер", "Yandex Browser"],
        "src_browser": ["Браузер", "Browser"],
        "src_web": ["веб", "web"],
        "src_yamusic": ["Яндекс Музыка", "Yandex Music"],
        "src_mediaplayer": ["Медиаплеер", "Media Player"],
        "src_media": ["Медиа", "Media"],
        "plat_vk": ["VK Музыка", "VK Music"],
        "plat_yandex": ["Яндекс Музыка", "Yandex Music"],
        "plat_yandex_short": ["Я.Музыка", "Y.Music"],

        // окно настроек
        "set_wintitle": ["Настройки Dynamic Island", "Dynamic Island Settings"],
        "set_title": ["Настройки", "Settings"],
        "set_appearance": ["ВНЕШНИЙ ВИД", "APPEARANCE"],
        "set_size": ["Размер", "Size"],
        "set_offset": ["Отступ сверху", "Top offset"],
        "set_shadow": ["Тень под островом", "Shadow under the island"],
        "set_vinyl": ["Обложка-пластинка", "Vinyl-style cover"],
        "set_color": ["ЦВЕТ И ПРОЗРАЧНОСТЬ", "COLOR & OPACITY"],
        "set_panelcolor": ["Цвет панели", "Panel color"],
        "set_hex": ["Свой цвет (HEX)", "Custom color (HEX)"],
        "set_opacity": ["Непрозрачность", "Opacity"],
        "set_glow": ["Подсветка цветом обложки", "Glow in cover color"],
        "set_accentcover": ["Акцент из обложки", "Accent from cover"],
        "set_bg": ["Фон острова", "Island background"],
        "set_bg_solid": ["Сплошной", "Solid"],
        "set_bg_cover": ["Градиент трека", "Track gradient"],
        "set_bg_custom": ["Свой градиент", "Custom gradient"],
        "set_gradcolor": ["Цвет градиента", "Gradient color"],
        "set_bghint": ["«Градиент трека» берёт цвет из обложки и меняется вместе с песней.", "“Track gradient” takes the color from the album art and changes with every song."],
        "set_accentcolor": ["Цвет акцента", "Accent color"],
        "set_music": ["МУЗЫКА", "MUSIC"],
        "set_lyrics": ["Текст песни", "Lyrics"],
        "set_volume": ["Ползунок громкости", "Volume slider"],
        "volume": ["Громкость", "Volume"],
        "volume_of": ["Громкость {0}", "{0} volume"],
        "set_playervolume": ["Для Spotify и «Музыки» — громкость плеера, а не системы", "Spotify & Music: control player volume, not system"],
        "set_compactlyrics": ["Текст в свёрнутом острове", "Lyrics in compact island"],
        "set_clock": ["Часы в свёрнутом острове", "Clock in compact island"],
        "set_openrecent": ["Прошлые треки открывать в", "Open recent tracks in"],
        "set_auto": ["Где играл", "Where played"],
        "set_recenthint": ["«Где играл» — откроется та площадка, где ты слушал трек. ПКМ по треку в списке — выбрать вручную.", "“Where played” opens the service where you listened to the track. Right-click a track in the list to choose manually."],
        "set_notifications": ["УВЕДОМЛЕНИЯ", "NOTIFICATIONS"],
        "set_winnotif": ["Уведомления macOS (эксперимент.)", "macOS notifications (experimental)"],
        "set_winnotif_hint": ["Читает базу Центра уведомлений. Нужен «Полный доступ к диску». Может перестать работать после обновления macOS.", "Reads the Notification Center database. Requires Full Disk Access. May break after a macOS update."],
        "set_dnd": ["Не беспокоить", "Do not disturb"],
        "set_duration": ["Длительность показа", "Display duration"],
        "set_test": ["Отправить тестовое уведомление", "Send test notification"],
        "set_system": ["СИСТЕМА", "SYSTEM"],
        "set_top": ["Всегда поверх окон", "Always on top"],
        "set_fullscreen": ["Прятать в полноэкранных приложениях и видео", "Hide in fullscreen apps and video"],
        "set_autostart": ["Запускать при входе в систему", "Launch at login"],
        "set_clicks": ["КЛИКИ СКВОЗЬ ОСТРОВ", "CLICK-THROUGH"],
        "set_clickthrough": ["Пропускать клики сквозь остров", "Let clicks pass through the island"],
        "set_clickhint": ["Клики проходят к окнам под островом везде, кроме кнопок, ползунка, списка треков и уведомлений.", "Clicks go to the windows under the island everywhere except buttons, the slider, the track list and notifications."],
        "set_events": ["СОБЫТИЯ В ОСТРОВЕ", "ISLAND EVENTS"],
        "set_ev_layout": ["Смена раскладки (RU / EN)", "Keyboard layout change (RU / EN)"],
        "set_ev_power": ["Зарядка и низкий заряд", "Charging and low battery"],
        "set_ev_bt": ["Подключение наушников по Bluetooth", "Bluetooth headphones connection"],
        "ev_charging": ["Зарядка", "Charging"],
        "ev_full": ["Заряжено", "Fully charged"],
        "ev_onbattery": ["От батареи", "On battery"],
        "ev_lowbattery": ["Низкий заряд", "Low battery"],
        "ev_bt_connected": ["Подключено", "Connected"],
        "ev_bt_disconnected": ["Отключено", "Disconnected"],
        "set_language": ["ЯЗЫК", "LANGUAGE"],
    ]

    static func t(_ key: String) -> String {
        guard let v = S[key] else { return key }
        let i = languages.firstIndex { $0.id == lang } ?? 0
        return i < v.count ? v[i] : v[0]
    }

    static func f(_ key: String, _ args: Any...) -> String {
        var s = t(key)
        for (i, a) in args.enumerated() {
            s = s.replacingOccurrences(of: "{\(i)}", with: "\(a)")
        }
        return s
    }

    /// Возвращает поддерживаемый код языка или nil.
    static func normalize(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty else { return nil }
        return languages.first { $0.id == id }?.id
    }

    /// Переключает язык; все SwiftUI-вью, наблюдающие LocModel, обновятся.
    static func apply(_ id: String?) {
        let l = normalize(id) ?? systemDefault()
        if LocModel.shared.lang != l { LocModel.shared.lang = l }
    }

    /// Язык системы: русский для ru/uk/be/kk, иначе английский.
    static func systemDefault() -> String {
        let two = String((Locale.preferredLanguages.first ?? "en").prefix(2)).lowercased()
        return ["ru", "uk", "be", "kk"].contains(two) ? "ru" : "en"
    }
}
