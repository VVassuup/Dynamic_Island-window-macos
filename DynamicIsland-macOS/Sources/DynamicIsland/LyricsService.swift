import Foundation

/// Синхронизированные тексты песен с бесплатного сервиса LRCLIB (lrclib.net).
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: [LyricLine]?] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["User-Agent": "DynamicIslandMac/1.0 (https://github.com)"]
        return URLSession(configuration: c)
    }()

    func get(artist: String, title: String, duration: Double, fromBrowser: Bool) async -> [LyricLine]? {
        let (a, t) = Self.normalize(artist, title, fromBrowser)
        if t.trimmingCharacters(in: .whitespaces).isEmpty { return nil }

        let key = (a + "|" + t).lowercased()
        if let cached = cache[key] { return cached }

        var result: [LyricLine]? = nil
        if !a.isEmpty {
            var c = URLComponents(string: "https://lrclib.net/api/get")!
            var q = [URLQueryItem(name: "artist_name", value: a), URLQueryItem(name: "track_name", value: t)]
            if duration > 0 { q.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
            c.queryItems = q
            if let url = c.url, let data = await fetch(url) {
                result = Self.parse(data, duration: duration, isArray: false)
            }
        }
        if result == nil {
            var c = URLComponents(string: "https://lrclib.net/api/search")!
            c.queryItems = [URLQueryItem(name: "q", value: (a + " " + t).trimmingCharacters(in: .whitespaces))]
            if let url = c.url, let data = await fetch(url) {
                result = Self.parse(data, duration: duration, isArray: true)
            }
        }
        cache[key] = result
        return result
    }

    private func fetch(_ url: URL) async -> Data? {
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch { return nil }
    }

    // MARK: - нормализация названий (как в оригинале)

    private static func rx(_ s: String, _ pattern: String, _ with: String = "", ci: Bool = false) -> String {
        guard let r = try? NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []) else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    static func normalize(_ artistIn: String, _ titleIn: String, _ fromBrowser: Bool) -> (String, String) {
        var artist = artistIn
        var title = titleIn

        // YouTube: "Исполнитель - Название (Official Video)"
        let dash = title.range(of: " - ") ?? title.range(of: " – ") ?? title.range(of: " — ")
        if let dash, dash.lowerBound > title.startIndex {
            let left = title[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = title[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if fromBrowser { artist = left; title = right } else { title = left } // "Song - Remastered 2011"
        }

        title = rx(title, #"\s*[\(\[【].*?[\)\]】]"#)
        title = rx(title, #"\s+(ft\.?|feat\.?|featuring)\s.*$"#, ci: true)
        title = title.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)

        artist = rx(artist, #"\s*-\s*Topic$"#, ci: true)
        artist = rx(artist, #"VEVO$"#, ci: true)
        artist = rx(artist, #"\s+(ft\.?|feat\.?)\s.*$"#, ci: true)
        artist = (artist.split(separator: ",").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        return (artist, title)
    }

    // MARK: - разбор ответа

    static func parse(_ data: Data, duration: Double, isArray: Bool) -> [LyricLine]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let items: [[String: Any]]
        if isArray { items = json as? [[String: Any]] ?? [] }
        else { items = (json as? [String: Any]).map { [$0] } ?? [] }

        var synced: String? = nil
        var plain: String? = nil
        for it in items {
            if synced == nil, let s = it["syncedLyrics"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { synced = s }
            if plain == nil, let p = it["plainLyrics"] as? String, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { plain = p }
            if synced != nil { break }
        }
        if let synced { return parseLrc(synced) }
        if let plain { return spread(plain, duration: duration) }
        return nil
    }

    private static let lrcLine = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\](.*)"#)

    static func parseLrc(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard let m = lrcLine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
                  let r3 = Range(m.range(at: 3), in: s) else { continue }
            let min = Double(s[r1]) ?? 0
            let sec = Double(s[r2].replacingOccurrences(of: ":", with: ".")) ?? 0
            lines.append(LyricLine(time: min * 60 + sec, text: s[r3].trimmingCharacters(in: .whitespaces)))
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Если есть только обычный текст — равномерно растягиваем его по длительности трека.
    static func spread(_ plain: String, duration: Double) -> [LyricLine]? {
        let rows = plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if rows.isEmpty { return nil }
        let d = duration > 0 ? duration : 180
        let step = d / Double(rows.count)
        return rows.enumerated().map { LyricLine(time: Double($0.offset) * step, text: $0.element) }
    }
}
