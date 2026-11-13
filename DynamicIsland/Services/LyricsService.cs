using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace DynamicIsland
{
    /// <summary>
    /// Синхронизированные тексты песен с бесплатного сервиса LRCLIB (lrclib.net).
    /// </summary>
    public static class LyricsService
    {
        static readonly HttpClient Http = CreateClient();
        static readonly Dictionary<string, List<LyricLine>> Cache = new Dictionary<string, List<LyricLine>>();
        static readonly Regex LrcLine = new Regex(@"\[(\d+):(\d+(?:[.:]\d+)?)\](.*)", RegexOptions.Compiled);

        static HttpClient CreateClient()
        {
            var c = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            c.DefaultRequestHeaders.UserAgent.ParseAdd("DynamicIslandWindows/1.0 (https://github.com)");
            return c;
        }

        public static async Task<List<LyricLine>> GetAsync(string artist, string title, double durationSeconds, bool fromBrowser)
        {
            var (a, t) = Normalize(artist, title, fromBrowser);
            if (string.IsNullOrWhiteSpace(t)) return null;

            var key = (a + "|" + t).ToLowerInvariant();
            if (Cache.TryGetValue(key, out var cached)) return cached;

            List<LyricLine> result = null;
            try
            {
                if (!string.IsNullOrWhiteSpace(a))
                {
                    var url = "https://lrclib.net/api/get?artist_name=" + Uri.EscapeDataString(a) +
                              "&track_name=" + Uri.EscapeDataString(t);
                    if (durationSeconds > 0) url += "&duration=" + ((int)Math.Round(durationSeconds)).ToString(CultureInfo.InvariantCulture);
                    var resp = await Http.GetAsync(url);
                    if (resp.IsSuccessStatusCode)
                        result = Parse(await resp.Content.ReadAsStringAsync(), durationSeconds, false);
                }

                if (result == null)
                {
                    var url = "https://lrclib.net/api/search?q=" + Uri.EscapeDataString((a + " " + t).Trim());
                    var resp = await Http.GetAsync(url);
                    if (resp.IsSuccessStatusCode)
                        result = Parse(await resp.Content.ReadAsStringAsync(), durationSeconds, true);
                }
            }
            catch { }

            if (Cache.Count >= 40) Cache.Clear();
            Cache[key] = result;
            return result;
        }

        static (string artist, string title) Normalize(string artist, string title, bool fromBrowser)
        {
            artist = artist ?? "";
            title = title ?? "";

            // YouTube: "Исполнитель - Название (Official Video)"
            int dash = title.IndexOf(" - ", StringComparison.Ordinal);
            if (dash < 0) dash = title.IndexOf(" – ", StringComparison.Ordinal);
            if (dash < 0) dash = title.IndexOf(" — ", StringComparison.Ordinal);
            if (dash > 0)
            {
                var left = title.Substring(0, dash).Trim();
                var right = title.Substring(dash + 3).Trim();
                if (fromBrowser) { artist = left; title = right; }
                else title = left; // "Song - Remastered 2011"
            }

            title = Regex.Replace(title, @"\s*[\(\[【].*?[\)\]】]", "");
            title = Regex.Replace(title, @"\s+(ft\.?|feat\.?|featuring)\s.*$", "", RegexOptions.IgnoreCase);
            title = title.Replace("\"", "").Trim();

            artist = Regex.Replace(artist, @"\s*-\s*Topic$", "", RegexOptions.IgnoreCase);
            artist = Regex.Replace(artist, @"VEVO$", "", RegexOptions.IgnoreCase);
            artist = Regex.Replace(artist, @"\s+(ft\.?|feat\.?)\s.*$", "", RegexOptions.IgnoreCase);
            artist = artist.Split(',')[0].Trim();

            return (artist, title);
        }

        static List<LyricLine> Parse(string json, double duration, bool isArray)
        {
            using var doc = JsonDocument.Parse(json);
            var items = isArray ? doc.RootElement.EnumerateArray().ToList() : new List<JsonElement> { doc.RootElement };

            string synced = null, plain = null;
            foreach (var it in items)
            {
                if (it.ValueKind != JsonValueKind.Object) continue;
                if (synced == null && it.TryGetProperty("syncedLyrics", out var s) && s.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(s.GetString()))
                    synced = s.GetString();
                if (plain == null && it.TryGetProperty("plainLyrics", out var p) && p.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(p.GetString()))
                    plain = p.GetString();
                if (synced != null) break;
            }

            if (synced != null) return ParseLrc(synced);
            if (plain != null) return Spread(plain, duration);
            return null;
        }

        static List<LyricLine> ParseLrc(string lrc)
        {
            var lines = new List<LyricLine>();
            foreach (var raw in lrc.Split('\n'))
            {
                var m = LrcLine.Match(raw.Trim());
                if (!m.Success) continue;
                int min = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                double sec = double.Parse(m.Groups[2].Value.Replace(':', '.'), CultureInfo.InvariantCulture);
                lines.Add(new LyricLine { Time = TimeSpan.FromSeconds(min * 60 + sec), Text = m.Groups[3].Value.Trim() });
            }
            return lines.OrderBy(l => l.Time).ToList();
        }

        // Если есть только обычный текст — равномерно растягиваем его по длительности трека
        static List<LyricLine> Spread(string plain, double duration)
        {
            var rows = plain.Split('\n').Select(r => r.Trim()).Where(r => r.Length > 0).ToList();
            if (rows.Count == 0) return null;
            if (duration <= 0) duration = 180;
            double step = duration / rows.Count;
            return rows.Select((r, i) => new LyricLine { Time = TimeSpan.FromSeconds(i * step), Text = r }).ToList();
        }
    }
}
