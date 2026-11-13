using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;
using Windows.Devices.Enumeration.Pnp;

namespace DynamicIsland
{
    public enum LiveEventKind { Layout, Power, Bluetooth }

    /// <summary>Короткое «живое» событие в острове: раскладка, зарядка, наушники.</summary>
    public class LiveEvent
    {
        public LiveEventKind Kind { get; set; }
        public string Glyph { get; set; }
        public string Title { get; set; }
        public string Value { get; set; }
        /// <summary>Цвет значка и значения. null — акцентный цвет острова.</summary>
        public Color? Tint { get; set; }
        public double Seconds { get; set; } = 2;
    }

    /// <summary>
    /// Следит за сменой раскладки клавиатуры, подключением зарядки / низким зарядом
    /// и подключением Bluetooth-наушников. События приходят из фоновых потоков.
    /// </summary>
    public sealed class LiveEventsService : IDisposable
    {
        public event Action<LiveEvent> Event;

        static readonly Color Green = Color.FromRgb(0x34, 0xC7, 0x59);
        static readonly Color Red = Color.FromRgb(0xFF, 0x45, 0x3A);
        static readonly Color Gray = Color.FromRgb(0x8E, 0x8E, 0x93);

        const string GlyphKeyboard = "\uE765";
        const string GlyphHeadphones = "\uE7F6";
        const string GlyphSpeaker = "\uE7F5";

        Timer _timer;
        int _busy, _tickCount;

        // ------------------------------------------------------------------ lifecycle

        public void Start()
        {
            _timer = new Timer(_ => Tick(), null, 500, 200);
            StartBluetooth();
        }

        public void Dispose()
        {
            try { _timer?.Dispose(); } catch { }
            _timer = null;
            try
            {
                if (_watcher != null &&
                    (_watcher.Status == DeviceWatcherStatus.Started || _watcher.Status == DeviceWatcherStatus.EnumerationCompleted))
                    _watcher.Stop();
            }
            catch { }
        }

        void Tick()
        {
            if (Interlocked.Exchange(ref _busy, 1) == 1) return;
            try
            {
                PollLayout();
                if (_tickCount++ % 5 == 0) PollPower(); // раз в секунду
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
            finally { Interlocked.Exchange(ref _busy, 0); }
        }

        void Raise(LiveEvent e)
        {
            try { Event?.Invoke(e); } catch (Exception ex) { Debug.WriteLine(ex); }
        }

        // ------------------------------------------------------------------ раскладка

        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint idThread);

        IntPtr _lastFg;
        int _lastLang = -1;

        void PollLayout()
        {
            var fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) return;
            uint tid = GetWindowThreadProcessId(fg, out _);
            int lang = (int)((long)GetKeyboardLayout(tid) & 0xFFFF);
            if (lang == 0) return;

            int prev = _lastLang;
            bool sameWindow = fg == _lastFg;
            _lastFg = fg;
            _lastLang = lang;

            // первый запуск или переключение на другое окно (у него может быть своя раскладка) — молча запоминаем
            if (prev == -1 || !sameWindow || prev == lang) return;

            string code, name;
            try
            {
                var ci = CultureInfo.GetCultureInfo(lang);
                code = ShortCode(ci.TwoLetterISOLanguageName);
                var neutral = ci.IsNeutralCulture || ci.Parent == null || ci.Parent == CultureInfo.InvariantCulture ? ci : ci.Parent;
                name = neutral.NativeName;
                if (!string.IsNullOrEmpty(name)) name = char.ToUpper(name[0], ci) + name.Substring(1);
            }
            catch
            {
                code = "0x" + lang.ToString("X4");
                name = Loc.T("ev_layout");
            }

            Raise(new LiveEvent
            {
                Kind = LiveEventKind.Layout,
                Glyph = GlyphKeyboard,
                Title = name,
                Value = code,
                Seconds = 1.3
            });
        }

        static string ShortCode(string iso) => iso switch
        {
            "uk" => "UA",
            "be" => "BY",
            "kk" => "KZ",
            "ka" => "GE",
            "hy" => "AM",
            _ => (iso ?? "").ToUpperInvariant()
        };

        // ------------------------------------------------------------------ зарядка

        bool? _lastOnline;
        bool _warned20, _warned10;

        void PollPower()
        {
            var ps = System.Windows.Forms.SystemInformation.PowerStatus;
            var status = ps.BatteryChargeStatus;
            if ((status & System.Windows.Forms.BatteryChargeStatus.NoSystemBattery) != 0 ||
                status == System.Windows.Forms.BatteryChargeStatus.Unknown) return;   // ПК без батареи
            if (ps.BatteryLifePercent < 0 || ps.BatteryLifePercent > 1) return;

            int pct = (int)Math.Round(ps.BatteryLifePercent * 100);
            bool online = ps.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online;

            bool? prev = _lastOnline;
            _lastOnline = online;

            if (online) { _warned20 = _warned10 = false; }

            if (prev.HasValue && prev.Value != online)
            {
                Raise(new LiveEvent
                {
                    Kind = LiveEventKind.Power,
                    Glyph = BatteryGlyph(pct, online),
                    Title = online ? Loc.T(pct >= 100 ? "ev_full" : "ev_charging") : Loc.T("ev_onbattery"),
                    Value = pct + "%",
                    Tint = online ? Green : (pct <= 20 ? Red : (Color?)null),
                    Seconds = 2.2
                });
                return;
            }

            if (!online && prev.HasValue)
            {
                bool warn = false;
                if (pct <= 10 && !_warned10) { _warned10 = _warned20 = true; warn = true; }
                else if (pct <= 20 && !_warned20) { _warned20 = true; warn = true; }
                if (warn)
                {
                    Raise(new LiveEvent
                    {
                        Kind = LiveEventKind.Power,
                        Glyph = BatteryGlyph(pct, false),
                        Title = Loc.T("ev_lowbattery"),
                        Value = pct + "%",
                        Tint = Red,
                        Seconds = 3.5
                    });
                }
            }
            else if (!prev.HasValue && !online)
            {
                // при запуске уже разряжено — не пугаем сразу, но и не повторяем предупреждение
                if (pct <= 10) _warned10 = _warned20 = true;
                else if (pct <= 20) _warned20 = true;
            }
        }

        /// <summary>Segoe Fluent / MDL2: Battery0…10 = EBA0…EBAA, BatteryCharging0…10 = EBAB…EBB5.</summary>
        static string BatteryGlyph(int pct, bool charging)
        {
            int step = Math.Max(0, Math.Min(10, (int)Math.Round(pct / 10.0)));
            return char.ConvertFromUtf32((charging ? 0xEBAB : 0xEBA0) + step);
        }

        // ------------------------------------------------------------------ Bluetooth

        const string IsConnectedKey = "System.Devices.Aep.IsConnected";
        const string ContainerKey = "System.Devices.Aep.ContainerId";
        const string BatteryKey = "{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2"; // DEVPKEY_Bluetooth_Battery

        class BtDevice
        {
            public string Id, Name;
            public bool Connected;
            public Guid? Container;
            public bool? Audio;
            public bool Speaker;
        }

        DeviceWatcher _watcher;
        readonly Dictionary<string, BtDevice> _devices = new Dictionary<string, BtDevice>();
        readonly object _lock = new object();
        volatile bool _enumerated;

        void StartBluetooth()
        {
            try
            {
                _watcher = DeviceInformation.CreateWatcher(
                    BluetoothDevice.GetDeviceSelectorFromPairingState(true),
                    new[] { IsConnectedKey, ContainerKey },
                    DeviceInformationKind.AssociationEndpoint);

                _watcher.Added += (w, info) =>
                {
                    var d = new BtDevice
                    {
                        Id = info.Id,
                        Name = info.Name,
                        Connected = GetBool(info.Properties, IsConnectedKey),
                        Container = GetGuid(info.Properties, ContainerKey)
                    };
                    lock (_lock) _devices[info.Id] = d;
                    if (_enumerated && d.Connected) _ = OnConnectionChangedAsync(d, true);
                };

                _watcher.Updated += (w, upd) =>
                {
                    BtDevice d;
                    lock (_lock) { if (!_devices.TryGetValue(upd.Id, out d)) return; }
                    if (!upd.Properties.TryGetValue(IsConnectedKey, out var v) || !(v is bool now)) return;
                    if (now == d.Connected) return;
                    d.Connected = now;
                    if (_enumerated) _ = OnConnectionChangedAsync(d, now);
                };

                _watcher.Removed += (w, upd) => { lock (_lock) _devices.Remove(upd.Id); };
                _watcher.EnumerationCompleted += (w, o) => _enumerated = true;
                _watcher.Start();
            }
            catch (Exception ex)
            {
                Debug.WriteLine(ex);   // нет Bluetooth-адаптера или служба выключена — просто без этой функции
            }
        }

        async Task OnConnectionChangedAsync(BtDevice d, bool connected)
        {
            try
            {
                if (d.Audio == null) await DetectAudioAsync(d);
                if (d.Audio != true) return;   // мыши, клавиатуры, телефоны — не показываем

                int? battery = null;
                if (connected)
                {
                    // заряд наушники присылают через пару секунд после подключения
                    battery = await ReadBatteryAsync(d);
                    if (battery == null)
                    {
                        await Task.Delay(2000);
                        if (!d.Connected) return;
                        battery = await ReadBatteryAsync(d);
                    }
                }
                else
                {
                    // короткие «моргания» соединения не показываем
                    await Task.Delay(1200);
                    if (d.Connected) return;
                }

                Raise(new LiveEvent
                {
                    Kind = LiveEventKind.Bluetooth,
                    Glyph = d.Speaker ? GlyphSpeaker : GlyphHeadphones,
                    Title = string.IsNullOrWhiteSpace(d.Name) ? "Bluetooth" : d.Name,
                    Value = connected
                        ? (battery.HasValue ? battery.Value + "%" : Loc.T("ev_bt_connected"))
                        : Loc.T("ev_bt_disconnected"),
                    Tint = connected ? (battery.HasValue && battery.Value <= 20 ? Red : (Color?)null) : Gray,
                    Seconds = 2.6
                });
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
        }

        static async Task DetectAudioAsync(BtDevice d)
        {
            try
            {
                using var bd = await BluetoothDevice.FromIdAsync(d.Id);
                if (bd != null)
                {
                    var cod = bd.ClassOfDevice;
                    d.Audio = cod.MajorClass == BluetoothMajorClass.AudioVideo;
                    d.Speaker = cod.MinorClass == BluetoothMinorClass.AudioVideoLoudspeaker;
                    return;
                }
            }
            catch (Exception ex) { Debug.WriteLine(ex); }

            // запасной вариант — по названию
            var n = (d.Name ?? "").ToLowerInvariant();
            string[] hints = { "airpods", "buds", "headphone", "headset", "наушник", "wh-", "wf-", "jbl", "beats", "earbuds", "pods", "marshall", "sony", "bose", "sennheiser" };
            foreach (var h in hints) if (n.Contains(h)) { d.Audio = true; return; }
            d.Audio = false;
        }

        static async Task<int?> ReadBatteryAsync(BtDevice d)
        {
            if (d.Container == null) return null;
            try
            {
                var aqs = "System.Devices.ContainerId:=\"" + d.Container.Value.ToString("B") + "\"";
                var list = await PnpObject.FindAllAsync(PnpObjectType.Device, new[] { BatteryKey }, aqs);
                foreach (var o in list)
                {
                    if (o.Properties.TryGetValue(BatteryKey, out var v) && v != null)
                    {
                        int p = Convert.ToInt32(v, CultureInfo.InvariantCulture);
                        if (p >= 0 && p <= 100) return p;
                    }
                }
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
            return null;
        }

        static bool GetBool(IReadOnlyDictionary<string, object> props, string key) =>
            props != null && props.TryGetValue(key, out var v) && v is bool b && b;

        static Guid? GetGuid(IReadOnlyDictionary<string, object> props, string key) =>
            props != null && props.TryGetValue(key, out var v) && v is Guid g ? g : (Guid?)null;
    }
}
