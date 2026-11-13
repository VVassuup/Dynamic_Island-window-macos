import AppKit
import SQLite3

/// ЭКСПЕРИМЕНТАЛЬНО. macOS не даёт приложениям публичного API для чтения чужих уведомлений
/// (аналога UserNotificationListener из Windows нет). Здесь мы читаем базу Центра уведомлений
/// в режиме «только чтение». Нужен «Полный доступ к диску». Формат базы приватный
/// и может поменяться в любом обновлении macOS.
final class NotificationReader {
    var onNotification: ((NotificationItem) -> Void)?

    private var timer: Timer?
    private var lastId: Int64 = -1
    private var reportedNoAccess = false
    private let q = DispatchQueue(label: "dynamicisland.notifications", qos: .utility)

    var isRunning: Bool { timer != nil }

    static var dbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let modern = home + "/Library/Group Containers/group.com.apple.usernoted/db2/db" // macOS 15+
        if FileManager.default.fileExists(atPath: modern) { return modern }
        // macOS 13–14: $DARWIN_USER_DIR/com.apple.notificationcenter/db2/db
        let userDir = (NSTemporaryDirectory() as NSString).deletingLastPathComponent + "/0"
        return userDir + "/com.apple.notificationcenter/db2/db"
    }

    func start() {
        guard timer == nil else { return }
        lastId = -1
        reportedNoAccess = false
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let path = Self.dbPath
        q.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                if db != nil { sqlite3_close(db) }
                self.reportNoAccess()
                return
            }
            defer { sqlite3_close(db) }

            if self.lastId < 0 {
                // при старте запоминаем последний id, чтобы не показывать старые уведомления
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(rec_id), 0) FROM record", -1, &st, nil) == SQLITE_OK,
                   sqlite3_step(st) == SQLITE_ROW {
                    self.lastId = sqlite3_column_int64(st, 0)
                } else {
                    self.reportNoAccess()
                }
                sqlite3_finalize(st)
                return
            }

            let sql = """
            SELECT r.rec_id, IFNULL(a.identifier, ''), r.data
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 20
            """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); return }
            sqlite3_bind_int64(st, 1, self.lastId)
            var items: [(String, String, String, String)] = []
            while sqlite3_step(st) == SQLITE_ROW {
                self.lastId = sqlite3_column_int64(st, 0)
                var bundle = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
                let len = Int(sqlite3_column_bytes(st, 2))
                guard len > 0, let blob = sqlite3_column_blob(st, 2) else { continue }
                let data = Data(bytes: blob, count: len)
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                if let app = plist["app"] as? String, !app.isEmpty { bundle = app }
                let req = plist["req"] as? [String: Any] ?? [:]
                let title = req["titl"] as? String ?? ""
                let sub = req["subt"] as? String ?? ""
                let body = req["body"] as? String ?? ""
                if title.isEmpty && body.isEmpty { continue }
                if bundle == Bundle.main.bundleIdentifier { continue }
                items.append((bundle, title, sub, body))
            }
            sqlite3_finalize(st)

            guard !items.isEmpty else { return }
            DispatchQueue.main.async {
                for (bundle, title, sub, body) in items {
                    let name = AppInfo.displayName(bundle) ?? bundle
                    let text = sub.isEmpty ? body : (body.isEmpty ? sub : sub + "\n" + body)
                    self.onNotification?(NotificationItem(appName: name, title: title.isEmpty ? name : title,
                                                          body: text, icon: AppInfo.icon(bundle)))
                }
            }
        }
    }

    private func reportNoAccess() {
        guard !reportedNoAccess else { return }
        reportedNoAccess = true
        DispatchQueue.main.async {
            self.onNotification?(NotificationItem(appName: "Dynamic Island", title: Loc.t("noaccess_title"),
                                                  body: Loc.t("noaccess_body"), icon: NSApp.applicationIconImage, force: true))
        }
    }
}
