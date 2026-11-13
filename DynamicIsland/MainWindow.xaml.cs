using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace DynamicIsland
{
    public enum IslandState { Compact, Expanded, Notification, Activity }

    /// <summary>
    /// Остров. Внешний вид и расположение элементов — как в macOS-версии (IslandView.swift).
    /// </summary>
    public partial class MainWindow : Window
    {
        // размеры из macOS-версии
        const double ExpandedWidth = 400;
        const double NotificationWidth = 380;
        const double CompactLyricsWidth = 330;
        const double CompactRadius = 17, ExpandedRadius = 32, NotificationRadius = 28;
        /// <summary>Запас прозрачного места над островом, чтобы свечение не обрезалось краем окна.</summary>
        const double GlowPad = 40;
        const int MaxRecent = 6;

        static readonly int[] FgLevels = { 75, 65, 60, 55, 50, 45, 40, 18, 16, 14, 10, 9, 8, 7 };
        static readonly SolidColorBrush DarkIcon = Frozen(Color.FromArgb(0x8C, 0, 0, 0)); // black .55

        readonly MediaService _media = new MediaService();
        readonly NotificationService _notifications = new NotificationService();
        readonly SystemMonitor _sys = new SystemMonitor();
        readonly VolumeService _volume = new VolumeService();
        readonly Queue<NotificationItem> _queue = new Queue<NotificationItem>();
        readonly ObservableCollection<TrackInfo> _recent = new ObservableCollection<TrackInfo>();
        readonly DispatcherTimer _tick, _collapseTimer, _notifTimer, _fullscreenTimer, _sysTimer, _topTimer, _passTimer;
        readonly Storyboard _eq = new Storyboard();

        IslandState _state = IslandState.Compact;
        bool _hover, _showRecent, _dragging, _notificationActive, _eqStarted, _menuOpen, _compactLyricActive;
        bool? _lastPlaying;
        string _page = "music";
        List<LyricLine> _lyrics;
        string _lyricsKey;
        TrackInfo _lastTrack;
        double _discAngle;
        DateTime _lastFrame = DateTime.Now;
        IntPtr _hwnd, _winHook;
        string _uiLang;
        bool _passThrough;          // окно сейчас пропускает клики насквозь (WS_EX_TRANSPARENT)
        WinEventDelegate _winEventProc;

        // громкость
        double _vol = 0.5, _volStart, _volStartY;
        bool _muted, _volAvailable, _volDragging, _volMoved, _volHover, _volActiveShown;

        // «живые» события: раскладка, зарядка, Bluetooth-наушники
        readonly LiveEventsService _live = new LiveEventsService();
        readonly DispatcherTimer _activityTimer = new DispatcherTimer();
        bool _activityActive;

        static SolidColorBrush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

        public MainWindow()
        {
            InitializeComponent();
            RecentList.ItemsSource = _recent;
            _page = App.Settings.LastPage == "system" ? "system" : "music";

            _tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            _tick.Tick += (s, e) => UpdateProgress();
            _tick.Start();

            _collapseTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
            _collapseTimer.Tick += (s, e) =>
            {
                _collapseTimer.Stop();
                if (!_hover && !_menuOpen && !_volDragging && _state == IslandState.Expanded)
                {
                    _showRecent = false;
                    UpdatePageVisuals();
                    GoTo(IslandState.Compact);
                }
            };

            _notifTimer = new DispatcherTimer();
            _notifTimer.Tick += (s, e) => { _notifTimer.Stop(); ShowNextNotification(); };

            _fullscreenTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
            _fullscreenTimer.Tick += (s, e) => CheckFullscreen();
            _fullscreenTimer.Start();

            _sysTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _sysTimer.Tick += (s, e) =>
            {
                var snap = _sys.Sample();
                if (_state == IslandState.Expanded && _page == "system" && !_showRecent) UpdateSystem(snap);
            };
            _sysTimer.Start();

            // «Всегда поверх»: периодически возвращаем окно на верхний слой (после Alt+Tab и т.п.)
            _topTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
            _topTimer.Tick += (s, e) => KeepOnTop();

            // «Клики сквозь остров»: следим за курсором
            _passTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
            _passTimer.Tick += (s, e) => UpdatePassThrough();

            BuildEqualizer();
            _activityTimer.Tick += (s, e) => EndActivity();
            // покадровая анимация нужна только для «пластинки» — подписываемся по необходимости (UpdateRenderHook)

            // Экономия памяти: когда остров свёрнут, чистим мусор и отдаём неиспользуемую память Windows
            _trimTimer = new DispatcherTimer(DispatcherPriority.ApplicationIdle) { Interval = TimeSpan.FromSeconds(3) };
            _trimTimer.Tick += (s, e) => TrimMemory();
            _trimTimer.Start();
            SourceInitialized += (s, e) => { MakeToolWindow(); HookForeground(); _passTimer.Start(); };
            Closed += (s, e) =>
            {
                if (_winHook != IntPtr.Zero) UnhookWinEvent(_winHook);
                _volume.Dispose();
                _live.Dispose();
            };
            IsVisibleChanged += (s, e) => KeepOnTop();
            Loaded += OnLoaded;
            App.SettingsChanged += ApplySettings;
        }

        // ------------------------------------------------------------------ init

        async void OnLoaded(object sender, RoutedEventArgs e)
        {
            ApplySettings();
            OnTrackChanged();

            _volume.Changed += OnVolumeChanged;
            _volume.Start();

            _live.Event += ev => Dispatcher.BeginInvoke(new Action(() => ShowActivity(ev)));
            _live.Start();

            _media.TrackChanged += () => Dispatcher.BeginInvoke(new Action(OnTrackChanged));
            _media.PlaybackChanged += () => Dispatcher.BeginInvoke(new Action(OnPlaybackChanged));
            try { await _media.InitAsync(); }
            catch (Exception ex) { Debug.WriteLine(ex); }

            _notifications.NotificationReceived += n => Dispatcher.BeginInvoke(new Action(() => EnqueueNotification(n)));
            bool ok = await _notifications.InitAsync();
            if (!ok)
            {
                EnqueueNotification(new NotificationItem
                {
                    AppName = "Dynamic Island",
                    Title = Loc.T("noaccess_title"),
                    Body = Loc.T("noaccess_body"),
                    Force = true
                });
            }
        }

        void ApplySettings()
        {
            PositionWindow();
            ApplyAppearance();

            Topmost = App.Settings.AlwaysOnTop;
            if (App.Settings.AlwaysOnTop) { _topTimer.Start(); KeepOnTop(); }
            else _topTimer.Stop();

            if (!App.Settings.ShowLyrics) { _lyrics = null; _lyricsKey = null; }
            else if (_media.Current != null && _lyricsKey == null) LoadLyrics(_media.Current);
            if (!App.Settings.HideInFullscreen) Root.Visibility = Visibility.Visible;
            if (_uiLang != Loc.Lang) { _uiLang = Loc.Lang; RefreshLocalizedTexts(); }

            UpdateVolumeVisibility();
            UpdateVolumeVisuals();
            UpdatePageVisuals();
            UpdateLyricsVisibility();
            GoTo(_state);
        }

        void PositionWindow()
        {
            double s = Math.Max(0.5, Math.Min(2.0, App.Settings.Scale));
            RootScale.ScaleX = s;
            RootScale.ScaleY = s;
            Width = 480 * s;
            Height = 600 * s;
            Left = (SystemParameters.PrimaryScreenWidth - Width) / 2;
            Top = App.Settings.TopOffset - GlowPad * s; // остров остаётся на месте, а сверху есть место для свечения
        }

        LinearGradientBrush _bgGradient;

        /// <summary>Сплошной фон (tint == null) или градиент: оттенок цвета сверху-слева → цвет панели снизу-справа.</summary>
        void ApplyIslandBackground(Color baseColor, byte a, Color? tint)
        {
            if (!tint.HasValue)
            {
                _bgGradient = null;
                Island.Background = new SolidColorBrush(Color.FromArgb(a, baseColor.R, baseColor.G, baseColor.B));
                return;
            }

            var stops = ColorUtil.GradientColors(baseColor, tint.Value, a);
            if (_bgGradient == null || !ReferenceEquals(Island.Background, _bgGradient))
            {
                _bgGradient = ColorUtil.MakeGradient(stops);
                Island.Background = _bgGradient;
                return;
            }

            // смена трека — цвет перетекает плавно
            var d = TimeSpan.FromMilliseconds(700);
            for (int i = 0; i < stops.Length && i < _bgGradient.GradientStops.Count; i++)
                _bgGradient.GradientStops[i].BeginAnimation(GradientStop.ColorProperty,
                    new ColorAnimation(stops[i], d) { EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
        }

        /// <summary>Цвет, прозрачность, цвет текста, тень/подсветка, акцент и форма обложки — как в macOS.</summary>
        void ApplyAppearance()
        {
            var s = App.Settings;
            double opacity = Math.Max(0.15, Math.Min(1, s.IslandOpacity));
            byte a = (byte)Math.Round(opacity * 255);
            var baseColor = ColorUtil.Parse(s.IslandColor, Colors.Black);
            var cover = _media.Current?.Accent;

            // фон: сплошной или градиент (из цвета трека / своего цвета)
            Color? tint = null;
            if (s.BackgroundStyle == "cover") tint = cover;
            else if (s.BackgroundStyle == "custom") tint = ColorUtil.Parse(s.GradientColor, Color.FromRgb(0xFF, 0x37, 0x5F));
            ApplyIslandBackground(baseColor, a, tint);

            // светлый остров — чёрный текст, тёмный — белый
            double lum = ColorUtil.Luminance(baseColor);
            if (tint.HasValue) lum = (lum + ColorUtil.Luminance(ColorUtil.GradientStart(baseColor, tint.Value))) / 2;
            bool light = lum > 0.6 && opacity > 0.5;
            var fg = light ? Colors.Black : Colors.White;
            Resources["Fg"] = Frozen(fg);
            foreach (var p in FgLevels)
                Resources["Fg" + p.ToString("00")] = Frozen(Color.FromArgb((byte)Math.Round(255 * p / 100.0), fg.R, fg.G, fg.B));

            Color accent;
            if (s.AccentFromCover && cover.HasValue) accent = cover.Value;
            else
            {
                accent = ColorUtil.Parse(s.AccentColor, Colors.White);
                if (light && accent.R > 0xF0 && accent.G > 0xF0 && accent.B > 0xF0) accent = Colors.Black;
            }
            Resources["AccentBrush"] = Frozen(accent);

            // подсветка цветом обложки или обычная тень
            Effect fx = null;
            if (s.CoverGlow && cover.HasValue)
                fx = new DropShadowEffect { Color = cover.Value, BlurRadius = 36, ShadowDepth = 0, Opacity = 0.6 };
            else if (s.Shadow)
                fx = new DropShadowEffect { Color = Colors.Black, BlurRadius = 24, ShadowDepth = 5, Direction = 270, Opacity = 0.45 };

            // Эффект на самом острове выключает ClearType у всего текста внутри (он становится мыльным),
            // поэтому при непрозрачном острове эффект вешаем на подложку под ним.
            bool opaque = opacity >= 0.99;
            if (opaque)
            {
                Island.Effect = null;
                GlowLayer.Effect = fx;
                GlowLayer.Visibility = fx != null ? Visibility.Visible : Visibility.Collapsed;
            }
            else
            {
                Island.Effect = fx;
                GlowLayer.Effect = null;
                GlowLayer.Visibility = Visibility.Collapsed;
            }

            bool vinyl = s.VinylCover;
            bool hasCover = _media.Current?.Cover != null;
            CoverBox.CornerRadius = new CornerRadius(vinyl ? 29 : 12);
            Cover.CornerRadius = new CornerRadius(vinyl ? 27 : 12);
            Cover.Margin = new Thickness(vinyl ? 2.3 : 0);
            CoverBox.Background = vinyl ? Brushes.Black : (Brush)FindResource("Fg10");
            MiniCover.CornerRadius = MiniCoverImg.CornerRadius = new CornerRadius(vinyl ? 11 : 6);
            var hole = vinyl && hasCover ? Visibility.Visible : Visibility.Collapsed;
            DiscHole.Visibility = hole;
            DiscRing.Visibility = vinyl ? Visibility.Visible : Visibility.Collapsed;
            MiniHole.Visibility = hole;
            if (!vinyl) { DiscRotate.Angle = 0; MiniDiscRotate.Angle = 0; }

            UpdateVolumeVisuals();
        }

        // ------------------------------------------------------------------ states

        void GoTo(IslandState st)
        {
            _state = st;
            double w, h, r;

            if (st == IslandState.Expanded)
            {
                ExpandedView.Visibility = Visibility.Visible;
                w = ExpandedWidth;
                h = MeasureHeight(ExpandedView, w);
                r = ExpandedRadius;
            }
            else if (st == IslandState.Notification)
            {
                NotificationView.Visibility = Visibility.Visible;
                w = NotificationWidth;
                h = Math.Max(66, MeasureHeight(NotificationView, w));
                r = NotificationRadius;
            }
            else if (st == IslandState.Activity)
            {
                ActivityView.Visibility = Visibility.Visible;
                ActivityView.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                w = Math.Max(ActivityMinWidth, Math.Ceiling(ActivityView.DesiredSize.Width));
                h = ActivityHeight;
                r = ActivityHeight / 2;
            }
            else
            {
                var size = UpdateCompactContent();
                w = size.Width;
                h = size.Height;
                r = CompactRadius;
            }

            Island.CornerRadius = new CornerRadius(r);
            GlowLayer.CornerRadius = Island.CornerRadius;
            UpdateClip();
            AnimateSize(w, h);

            ShowView(CompactView, st == IslandState.Compact);
            ShowView(ExpandedView, st == IslandState.Expanded);
            ShowView(NotificationView, st == IslandState.Notification);
            ShowView(ActivityView, st == IslandState.Activity);
        }

        /// <summary>Свёрнутый остров: обложка · (часы или строка текста) · эквалайзер.</summary>
        Size UpdateCompactContent()
        {
            bool hasMedia = _media.Current != null;
            bool lyric = hasMedia && _compactLyricActive;
            bool clock = App.Settings.ShowClock && !lyric;
            MiniCoverHost.Visibility = hasMedia ? Visibility.Visible : Visibility.Collapsed;
            EqBars.Visibility = hasMedia ? Visibility.Visible : Visibility.Collapsed;
            CompactLyric.Visibility = lyric ? Visibility.Visible : Visibility.Collapsed;
            CompactLyricOld.Visibility = CompactLyric.Visibility;
            ClockText.Visibility = clock ? Visibility.Visible : Visibility.Collapsed;
            if (lyric) return new Size(CompactLyricsWidth, 36);
            if (hasMedia) return new Size(App.Settings.ShowClock ? 150 : 120, 34);
            return new Size(120, 34);
        }

        static double MeasureHeight(FrameworkElement el, double width)
        {
            el.Measure(new Size(width, double.PositiveInfinity));
            return Math.Ceiling(el.DesiredSize.Height);
        }

        /// <summary>«Пружина», близкая к .spring(response: 0.42, dampingFraction: 0.8).</summary>
        void AnimateSize(double w, double h)
        {
            var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.25 };
            var d = TimeSpan.FromMilliseconds(420);
            Island.BeginAnimation(WidthProperty, new DoubleAnimation(w, d) { EasingFunction = ease });
            Island.BeginAnimation(HeightProperty, new DoubleAnimation(h, d) { EasingFunction = ease });
            GlowLayer.BeginAnimation(WidthProperty, new DoubleAnimation(w, d) { EasingFunction = ease });
            GlowLayer.BeginAnimation(HeightProperty, new DoubleAnimation(h, d) { EasingFunction = ease });
        }

        void Island_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateClip();

        /// <summary>Скруглённая обрезка содержимого вместо прямоугольного ClipToBounds.</summary>
        void UpdateClip()
        {
            double w = Island.ActualWidth, h = Island.ActualHeight;
            if (w <= 0 || h <= 0) return;
            double r = Math.Min(Island.CornerRadius.TopLeft, Math.Min(w, h) / 2);
            IslandContent.Clip = new RectangleGeometry(new Rect(0, 0, w, h), r, r);
        }

        void ShowView(FrameworkElement el, bool show)
        {
            if (show)
            {
                el.Visibility = Visibility.Visible;
                el.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(220))
                {
                    BeginTime = TimeSpan.FromMilliseconds(110)
                });
            }
            else if (el.Visibility == Visibility.Visible)
            {
                var a = new DoubleAnimation(0, TimeSpan.FromMilliseconds(90));
                a.Completed += (s, e) => { if (!IsViewActive(el)) el.Visibility = Visibility.Collapsed; };
                el.BeginAnimation(OpacityProperty, a);
            }
        }

        bool IsViewActive(FrameworkElement el) =>
            (el == CompactView && _state == IslandState.Compact) ||
            (el == ExpandedView && _state == IslandState.Expanded) ||
            (el == NotificationView && _state == IslandState.Notification) ||
            (el == ActivityView && _state == IslandState.Activity);

        // ------------------------------------------------------------------ hover

        void Island_MouseEnter(object sender, MouseEventArgs e)
        {
            _hover = true;
            _collapseTimer.Stop();
            if (_state == IslandState.Activity)
            {
                _activityTimer.Stop();
                _activityActive = false;
                GoTo(IslandState.Expanded);
            }
            else if (_state == IslandState.Compact) GoTo(IslandState.Expanded);
        }

        void Island_MouseLeave(object sender, MouseEventArgs e)
        {
            _hover = false;
            if (_state == IslandState.Expanded) _collapseTimer.Start();
        }

        // ------------------------------------------------------------------ pages

        void TabMusic_Click(object sender, RoutedEventArgs e) => SetPage("music");
        void TabSystem_Click(object sender, RoutedEventArgs e) => SetPage("system");

        void SetPage(string page)
        {
            if (_page == page && !_showRecent) return;
            _showRecent = false;
            if (_page != page)
            {
                _page = page;
                App.Settings.LastPage = page;
                App.Settings.Save();
            }
            UpdatePageVisuals();
            if (page == "system") UpdateSystem(_sys.Sample());
            if (_state == IslandState.Expanded) GoTo(IslandState.Expanded);
        }

        /// <summary>Подсветка вкладок/кнопки «недавние» и видимая страница.</summary>
        void UpdatePageVisuals()
        {
            bool sys = _page == "system";
            MusicPage.Visibility = !_showRecent && !sys ? Visibility.Visible : Visibility.Collapsed;
            SystemPage.Visibility = !_showRecent && sys ? Visibility.Visible : Visibility.Collapsed;
            RecentPanel.Visibility = _showRecent ? Visibility.Visible : Visibility.Collapsed;
            TabMusic.Tag = !_showRecent && !sys ? "on" : null;
            TabSystem.Tag = !_showRecent && sys ? "on" : null;
            RecentButton.Tag = _showRecent ? "on" : null;
            RecentEmpty.Visibility = _recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        void UpdateSystem(SystemSnapshot s)
        {
            SetBar(CpuBar, CpuValue, s.Cpu);
            CpuSub.Text = Loc.F("sys_threads", Environment.ProcessorCount);
            SetBar(RamBar, RamValue, s.Ram);
            RamSub.Text = Loc.F("sys_ramsub", Gb(s.RamUsed), Gb(s.RamTotal));
            SetBar(DiskBar, DiskValue, s.Disk);
            DiskSub.Text = Loc.F("sys_disksub", s.DiskName, Gb((ulong)Math.Max(0, s.DiskFree)));
            NetDown.Text = "↓ " + Speed(s.Down);
            NetUp.Text = "↑ " + Speed(s.Up);

            if (s.Battery >= 0)
            {
                BatteryCard.Visibility = Visibility.Visible;
                SetBar(BatteryBar, BatteryValue, s.Battery);
                BatterySub.Text = s.Charging ? "⚡ " + Loc.T("sys_charging").Trim(' ', '·') : " ";
            }
            else BatteryCard.Visibility = Visibility.Collapsed;

            var up = TimeSpan.FromMilliseconds(Environment.TickCount64);
            UptimeText.Text = up.TotalDays >= 1
                ? Loc.F("sys_uptime_days", (int)up.TotalDays, up.Hours)
                : Loc.F("sys_uptime_hours", up.Hours, up.Minutes);
        }

        /// <summary>Полоса карточки — цветом акцента, как в macOS.</summary>
        static void SetBar(Border bar, TextBlock value, double pct)
        {
            value.Text = Math.Round(pct) + "%";
            if (bar.RenderTransform is ScaleTransform st)
            {
                st.BeginAnimation(ScaleTransform.ScaleXProperty,
                    new DoubleAnimation(Math.Max(0, Math.Min(1, pct / 100.0)), TimeSpan.FromMilliseconds(450))
                    {
                        EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
                    });
            }
        }

        static string Gb(ulong bytes) => (bytes / 1073741824.0).ToString("0.#");

        static string Speed(double bps)
        {
            if (bps >= 1048576) return (bps / 1048576).ToString("0.0") + Loc.T("unit_mbs");
            return (bps / 1024).ToString("0") + Loc.T("unit_kbs");
        }

        // ------------------------------------------------------------------ громкость (VolumePill)

        void OnVolumeChanged(double v, bool muted, bool available)
        {
            bool availChanged = available != _volAvailable;
            _volAvailable = available;
            _muted = muted;
            if (!_volDragging) _vol = v;
            UpdateVolumeVisuals();
            if (availChanged)
            {
                UpdateVolumeVisibility();
                if (_state == IslandState.Expanded) GoTo(IslandState.Expanded);
            }
        }

        /// <summary>Ползунок громкости или большой эквалайзер справа от названия трека.</summary>
        void UpdateVolumeVisibility()
        {
            bool show = App.Settings.ShowVolume && _volAvailable;
            VolumeHost.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            EqBarsBig.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        }

        double VolumeFraction => _muted ? 0 : Math.Max(0, Math.Min(1, _vol));

        void UpdateVolumeVisuals()
        {
            if (VolumePill == null) return;
            double frac = VolumeFraction;
            double h = VolumePill.ActualHeight > 0 ? VolumePill.ActualHeight : VolumePill.Height;
            VolumeFill.Height = Math.Max(0, h * frac);

            VolumeIcon.Text = frac < 0.001 ? "\uE74F"   // звук выключен
                            : frac < 0.34 ? "\uE993"    // 1 волна
                            : frac < 0.67 ? "\uE994"    // 2 волны
                            : "\uE995";                 // 3 волны
            if (frac > 0.22) VolumeIcon.Foreground = DarkIcon;
            else VolumeIcon.SetResourceReference(TextBlock.ForegroundProperty, "Fg60");

            VolumeHost.ToolTip = Loc.T("volume") + " " + Math.Round(frac * 100) + "%";
        }

        void VolumePill_SizeChanged(object sender, SizeChangedEventArgs e)
        {
            double w = VolumePill.ActualWidth, h = VolumePill.ActualHeight;
            if (w <= 0 || h <= 0) return;
            double r = w / 2.6;
            VolumePill.Clip = new RectangleGeometry(new Rect(0, 0, w, h), r, r);
            VolumeFill.Height = h * VolumeFraction;
        }

        /// <summary>При наведении/перетаскивании полоска чуть увеличивается: 16×44 → 20×52.</summary>
        void UpdatePillSize()
        {
            bool active = _volHover || _volDragging;
            if (active == _volActiveShown) return;
            _volActiveShown = active;
            var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.3 };
            var d = TimeSpan.FromMilliseconds(260);
            VolumePill.BeginAnimation(WidthProperty, new DoubleAnimation(active ? 20 : 16, d) { EasingFunction = ease });
            VolumePill.BeginAnimation(HeightProperty, new DoubleAnimation(active ? 52 : 44, d) { EasingFunction = ease });
            VolumeIcon.FontSize = active ? 9 : 7.5;
            VolumeIcon.Margin = new Thickness(0, 0, 0, active ? 6 : 5);
        }

        void SetVolume(double v)
        {
            v = Math.Max(0, Math.Min(1, v));
            _vol = v;
            if (_muted && v > 0) _muted = false;
            _volume.SetVolume(v);
            UpdateVolumeVisuals();
        }

        void ToggleMute()
        {
            _muted = !_muted;
            _volume.SetMuted(_muted);
            UpdateVolumeVisuals();
        }

        void Volume_MouseEnter(object sender, MouseEventArgs e) { _volHover = true; UpdatePillSize(); }

        void Volume_MouseLeave(object sender, MouseEventArgs e) { _volHover = false; UpdatePillSize(); }

        void Volume_Down(object sender, MouseButtonEventArgs e)
        {
            e.Handled = true;
            _volDragging = true;
            _volMoved = false;
            _volStartY = e.GetPosition(VolumeHost).Y;
            _volStart = VolumeFraction;
            VolumeHost.CaptureMouse();
            UpdatePillSize();
        }

        /// <summary>Относительное перетаскивание: вверх — громче, вниз — тише.</summary>
        void Volume_Move(object sender, MouseEventArgs e)
        {
            if (!_volDragging) return;
            double dy = _volStartY - e.GetPosition(VolumeHost).Y;
            if (Math.Abs(dy) > 2) _volMoved = true;
            if (!_volMoved) return;
            double h = VolumePill.ActualHeight > 0 ? VolumePill.ActualHeight : 52;
            SetVolume(_volStart + dy / h);
        }

        void Volume_Up(object sender, MouseButtonEventArgs e)
        {
            if (!_volDragging) return;
            e.Handled = true;
            _volDragging = false;
            VolumeHost.ReleaseMouseCapture();
            if (!_volMoved) ToggleMute();   // простой клик — вкл/выкл звук
            UpdatePillSize();
            if (!_hover && _state == IslandState.Expanded) _collapseTimer.Start();
        }

        void Volume_LostCapture(object sender, MouseEventArgs e)
        {
            if (!_volDragging) return;
            _volDragging = false;
            UpdatePillSize();
        }

        void Volume_Wheel(object sender, MouseWheelEventArgs e)
        {
            e.Handled = true;
            SetVolume(VolumeFraction + e.Delta / 120.0 * 0.04);
        }

        // ------------------------------------------------------------------ media

        /// <summary>Перерисовать тексты, заданные из кода, после смены языка.</summary>
        void RefreshLocalizedTexts()
        {
            var t = _media.Current;
            if (t != null)
            {
                if (string.IsNullOrWhiteSpace(t.Title)) TitleText.Text = Loc.T("media_untitled");
                SourceText.Text = t.PlatformLabel;
            }
            UpdateVolumeVisuals();
        }

        void OnTrackChanged()
        {
            var t = _media.Current;
            if (t == null)
            {
                NothingPanel.Visibility = Visibility.Visible;
                TrackPanel.Visibility = Visibility.Collapsed;
                TitleText.Text = "";
                ArtistText.Text = "";
                SourceText.Text = "";
                CoverBrush.ImageSource = null;
                MiniCoverBrush.ImageSource = null;
                _lyrics = null;
                _lyricsKey = null;
                ElapsedText.Text = "0:00";
                RemainingText.Text = "-0:00";
                ProgressSlider.Value = 0;
            }
            else
            {
                NothingPanel.Visibility = Visibility.Collapsed;
                TrackPanel.Visibility = Visibility.Visible;

                if (t.Cover == null && t.CoverBytes != null)
                {
                    t.Cover = ImageHelper.FromBytes(t.CoverBytes, 160);
                    t.Accent = ImageHelper.AverageColor(t.Cover);
                }

                // где реально играет трек (VK / Яндекс / YouTube / Spotify…)
                if (t.Platform == null)
                {
                    try { t.Platform = PlatformDetector.Detect(t); } catch (Exception ex) { Debug.WriteLine(ex); }
                }

                TitleText.Text = string.IsNullOrWhiteSpace(t.Title) ? Loc.T("media_untitled") : t.Title;
                ArtistText.Text = t.Artist ?? "";
                ArtistText.Visibility = string.IsNullOrWhiteSpace(t.Artist) ? Visibility.Collapsed : Visibility.Visible;
                SourceText.Text = t.PlatformLabel;
                SourceText.Visibility = string.IsNullOrWhiteSpace(t.PlatformLabel) ? Visibility.Collapsed : Visibility.Visible;
                CoverBrush.ImageSource = t.Cover;
                MiniCoverBrush.ImageSource = t.Cover;

                UpdateRecent(t);
                LoadLyrics(t);
            }

            ApplyAppearance();
            UpdateLyricsVisibility();
            OnPlaybackChanged();
            if (_state != IslandState.Notification) GoTo(_state);
        }

        void UpdateRecent(TrackInfo t)
        {
            if (_lastTrack != null && _lastTrack.Key != t.Key && !string.IsNullOrWhiteSpace(_lastTrack.Title))
            {
                for (int i = _recent.Count - 1; i >= 0; i--)
                    if (_recent[i].Key == _lastTrack.Key) _recent.RemoveAt(i);
                _recent.Insert(0, _lastTrack);
                while (_recent.Count > MaxRecent) _recent.RemoveAt(_recent.Count - 1);
            }
            for (int i = _recent.Count - 1; i >= 0; i--)
                if (_recent[i].Key == t.Key) _recent.RemoveAt(i);
            _lastTrack = t;
            RecentEmpty.Visibility = _recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        void OnPlaybackChanged()
        {
            bool playing = _media.Current?.IsPlaying == true;

            if (_lastPlaying != playing)
            {
                PlayIcon.Visibility = playing ? Visibility.Collapsed : Visibility.Visible;
                PauseIcon.Visibility = playing ? Visibility.Visible : Visibility.Collapsed;
                if (_lastPlaying.HasValue) Pop(playing ? PauseIcon : PlayIcon);
                _lastPlaying = playing;
            }

            if (playing)
            {
                if (!_eqStarted) { _eq.Begin(this, true); _eqStarted = true; }
                else _eq.Resume(this);
            }
            else if (_eqStarted)
            {
                _eq.Pause(this);
            }
        }

        /// <summary>Мягкая «пружинка» при смене иконки play/pause.</summary>
        static void Pop(UIElement el)
        {
            if (!(el.RenderTransform is ScaleTransform st)) return;
            var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.6 };
            var a = new DoubleAnimation(0.5, 1, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease };
            st.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            st.BeginAnimation(ScaleTransform.ScaleYProperty, a);
            el.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
        }

        void BuildEqualizer()
        {
            var rnd = new Random();
            int i = 0;
            foreach (var panel in new[] { EqBars, EqBarsBig })
            {
                foreach (var child in panel.Children)
                {
                    if (!(child is Rectangle rect)) continue;
                    var a = new DoubleAnimation(0.25, 1.0, TimeSpan.FromMilliseconds(260 + rnd.Next(0, 260)))
                    {
                        AutoReverse = true,
                        RepeatBehavior = RepeatBehavior.Forever,
                        BeginTime = TimeSpan.FromMilliseconds((i % 5) * 90),
                        EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
                    };
                    Storyboard.SetTarget(a, rect);
                    Storyboard.SetTargetProperty(a, new PropertyPath("(UIElement.RenderTransform).(ScaleTransform.ScaleY)"));
                    _eq.Children.Add(a);
                    i++;
                }
            }
        }

        DispatcherTimer _trimTimer;
        bool _renderHooked;
        DateTime _lastTrim = DateTime.MinValue;
        IslandState _lastTrimState = IslandState.Expanded;

        void UpdateRenderHook()
        {
            bool need = App.Settings.VinylCover && _media.Current?.IsPlaying == true && IsVisible;
            if (need == _renderHooked) return;
            _renderHooked = need;
            if (need) { _lastFrame = DateTime.Now; CompositionTarget.Rendering += OnRender; }
            else CompositionTarget.Rendering -= OnRender;
        }

        /// <summary>
        /// После сворачивания острова (и дальше раз в минуту, пока он свёрнут) собираем мусор
        /// и возвращаем Windows неиспользуемую память (именно её показывает Диспетчер задач).
        /// </summary>
        void TrimMemory()
        {
            var st = _state;
            bool justCollapsed = st == IslandState.Compact && _lastTrimState != IslandState.Compact;
            _lastTrimState = st;
            if (st != IslandState.Compact || _hover || _dragging) return;
            if (!justCollapsed && (DateTime.Now - _lastTrim).TotalSeconds < 60) return;
            _lastTrim = DateTime.Now;
            try
            {
                System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
                GC.Collect(2, GCCollectionMode.Forced, true, true);
                GC.WaitForPendingFinalizers();
                GC.Collect(2, GCCollectionMode.Forced, true, true);
                using var self = Process.GetCurrentProcess();
                SetProcessWorkingSetSize(self.Handle, (IntPtr)(-1), (IntPtr)(-1));
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
        }

        [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

        void OnRender(object sender, EventArgs e)
        {
            var now = DateTime.Now;
            double dt = (now - _lastFrame).TotalSeconds;
            _lastFrame = now;
            if (App.Settings.VinylCover && _media.Current?.IsPlaying == true)
            {
                _discAngle = (_discAngle + dt * 40) % 360;
                DiscRotate.Angle = _discAngle;
                MiniDiscRotate.Angle = _discAngle;
            }
        }

        void UpdateProgress()
        {
            UpdateRenderHook();
            ClockText.Text = DateTime.Now.ToString("HH:mm");

            var t = _media.Current;
            if (t == null) return;

            var pos = _media.GetPosition();
            var dur = t.Duration;
            var seekVis = dur.TotalSeconds > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (SeekPanel.Visibility != seekVis)
            {
                SeekPanel.Visibility = seekVis;
                if (_state == IslandState.Expanded) GoTo(IslandState.Expanded);
            }
            if (!_dragging && dur.TotalSeconds > 0)
            {
                ProgressSlider.Maximum = dur.TotalSeconds;
                ProgressSlider.Value = Math.Min(pos.TotalSeconds, dur.TotalSeconds);
            }
            var shown = _dragging ? TimeSpan.FromSeconds(ProgressSlider.Value) : pos;
            ElapsedText.Text = Fmt(shown);
            RemainingText.Text = dur > TimeSpan.Zero ? "-" + Fmt(dur - shown) : "";

            if (_lyrics != null && _lyrics.Count > 0)
            {
                int idx = -1;
                var probe = pos + TimeSpan.FromMilliseconds(300);
                for (int i = 0; i < _lyrics.Count; i++)
                {
                    if (_lyrics[i].Time <= probe) idx = i; else break;
                }
                string cur = idx >= 0 && !string.IsNullOrWhiteSpace(_lyrics[idx].Text) ? _lyrics[idx].Text : "♪";
                string next = idx + 1 < _lyrics.Count ? _lyrics[idx + 1].Text : "";
                if (LyricCurrent.Text != cur)
                {
                    LyricCurrent.Text = cur;
                    LyricCurrent.BeginAnimation(OpacityProperty, new DoubleAnimation(0.15, 1, TimeSpan.FromMilliseconds(300)));
                }
                LyricNext.Text = next;
                LyricNext.Visibility = string.IsNullOrEmpty(next) ? Visibility.Collapsed : Visibility.Visible;

                // строка текста в свёрнутом острове
                if (_compactLyricActive && CompactLyric.Text != cur)
                    AnimateCompactLyric(cur);
            }
        }

        /// <summary>
        /// Смена строки в свёрнутом острове: старая строка уходит вверх и гаснет, новая поднимается снизу.
        /// Плавное замедление без «доводки» на последнем пикселе.
        /// </summary>
        void AnimateCompactLyric(string text)
        {
            string prev = CompactLyric.Text;
            double prevOpacity = CompactLyric.Opacity;
            double prevY = CompactLyricShift.Y;

            if (!string.IsNullOrEmpty(prev))
            {
                CompactLyricOld.Text = prev;
                var outD = TimeSpan.FromMilliseconds(300);
                CompactLyricOld.BeginAnimation(OpacityProperty, new DoubleAnimation(prevOpacity, 0, outD)
                { EasingFunction = new SineEase { EasingMode = EasingMode.EaseIn } });
                CompactLyricOldShift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(prevY, -10, outD)
                { EasingFunction = new SineEase { EasingMode = EasingMode.EaseIn } });
            }

            CompactLyric.Text = text;
            var inD = TimeSpan.FromMilliseconds(520);
            CompactLyric.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(380))
            { EasingFunction = new SineEase { EasingMode = EasingMode.EaseOut } });
            CompactLyricShift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(10, 0, inD)
            { EasingFunction = new QuinticEase { EasingMode = EasingMode.EaseOut } });
        }

        static string Fmt(TimeSpan ts)
        {
            if (ts < TimeSpan.Zero) ts = TimeSpan.Zero;
            return $"{(int)ts.TotalMinutes}:{ts.Seconds:00}";
        }

        async void LoadLyrics(TrackInfo t)
        {
            if (!App.Settings.ShowLyrics) { _lyrics = null; _lyricsKey = null; return; }
            var key = t.Key;
            if (key == _lyricsKey) return;
            _lyricsKey = key;
            _lyrics = null;
            LyricCurrent.Text = "";
            LyricNext.Text = "";
            CompactLyric.Text = "";
            UpdateLyricsVisibility();

            List<LyricLine> result = null;
            try { result = await LyricsService.GetAsync(t.Artist, t.Title, t.Duration.TotalSeconds, t.IsBrowser); }
            catch (Exception ex) { Debug.WriteLine(ex); }
            if (_lyricsKey != key) return;
            _lyrics = result;
            UpdateLyricsVisibility();
            UpdateProgress();
            if (_state == IslandState.Expanded) GoTo(IslandState.Expanded);
        }

        void UpdateLyricsVisibility()
        {
            bool has = App.Settings.ShowLyrics && _media.Current != null && _lyrics != null && _lyrics.Count > 0;
            LyricsPanel.Visibility = has ? Visibility.Visible : Visibility.Collapsed;

            bool compact = has && App.Settings.CompactLyrics;
            if (compact != _compactLyricActive)
            {
                _compactLyricActive = compact;
                if (!compact) CompactLyric.Text = "";
                if (_state == IslandState.Compact) GoTo(IslandState.Compact);
            }
        }

        // ------------------------------------------------------------------ buttons

        async void Prev_Click(object sender, RoutedEventArgs e) => await _media.PreviousAsync();
        async void Next_Click(object sender, RoutedEventArgs e) => await _media.NextAsync();
        async void PlayPause_Click(object sender, RoutedEventArgs e) => await _media.PlayPauseAsync();
        void Settings_Click(object sender, RoutedEventArgs e) => App.ShowSettings();

        void Recent_Click(object sender, RoutedEventArgs e)
        {
            _showRecent = !_showRecent;
            UpdatePageVisuals();
            if (!_showRecent && _page == "system") UpdateSystem(_sys.Sample());
            GoTo(IslandState.Expanded);
        }

        static string ResolvePlatform(TrackInfo t)
        {
            var p = App.Settings.RecentPlatform;
            if (!string.IsNullOrEmpty(p) && p != "auto") return p;
            return t.Platform ?? "youtube";
        }

        void RecentItem_Click(object sender, MouseButtonEventArgs e)
        {
            if ((sender as FrameworkElement)?.Tag is TrackInfo t) Platforms.Open(ResolvePlatform(t), t);
        }

        void RecentItem_RightClick(object sender, MouseButtonEventArgs e)
        {
            if (!((sender as FrameworkElement)?.Tag is TrackInfo t)) return;
            e.Handled = true;

            var menu = new ContextMenu();
            foreach (var p in Platforms.All)
            {
                var id = p.Id;
                var mi = new MenuItem
                {
                    Header = Loc.F("menu_openin", p.Name),
                    FontWeight = id == t.Platform ? FontWeights.SemiBold : FontWeights.Normal
                };
                mi.Click += (s2, e2) => Platforms.Open(id, t);
                menu.Items.Add(mi);
            }
            menu.Items.Add(new Separator());
            var copy = new MenuItem { Header = Loc.T("menu_copy") };
            copy.Click += (s2, e2) =>
            {
                try { Clipboard.SetText(((t.Artist ?? "") + " — " + (t.Title ?? "")).Trim(' ', '—')); }
                catch (Exception ex) { Debug.WriteLine(ex); }
            };
            menu.Items.Add(copy);

            _menuOpen = true;
            menu.Closed += (s2, e2) =>
            {
                _menuOpen = false;
                if (!_hover && _state == IslandState.Expanded) _collapseTimer.Start();
            };
            menu.PlacementTarget = (UIElement)sender;
            menu.IsOpen = true;
        }

        void Progress_Down(object sender, MouseButtonEventArgs e) => _dragging = true;

        async void Progress_Up(object sender, MouseButtonEventArgs e)
        {
            var target = TimeSpan.FromSeconds(ProgressSlider.Value);
            _dragging = false;
            await _media.SeekAsync(target);
        }

        // ------------------------------------------------------------------ notifications

        public void EnqueueNotification(NotificationItem n)
        {
            if (!n.Force)
            {
                if (App.Settings.DoNotDisturb) return;
                if (n.IsTelegram && !App.Settings.TelegramNotifications) return;
                if (!n.IsTelegram && !App.Settings.WindowsNotifications) return;
            }
            _queue.Enqueue(n);
            if (!_notificationActive) ShowNextNotification();
        }

        // ------------------------------------------------------------------ live events

        const double ActivityHeight = 36, ActivityMinWidth = 230;

        /// <summary>Коротко показывает событие (раскладка / зарядка / наушники) в виде широкой «таблетки».</summary>
        void ShowActivity(LiveEvent ev)
        {
            if (ev == null) return;
            var s = App.Settings;
            if (ev.Kind == LiveEventKind.Layout && !s.ShowLayoutChange) return;
            if (ev.Kind == LiveEventKind.Power && !s.ShowCharging) return;
            if (ev.Kind == LiveEventKind.Bluetooth && !s.ShowBluetooth) return;

            // не перебиваем уведомления и раскрытый остров; в полноэкранном режиме остров скрыт
            if (_notificationActive || _hover || _menuOpen || _dragging) return;
            if (_state != IslandState.Compact && _state != IslandState.Activity) return;
            if (!Island.IsVisible) return;

            ActivityGlyph.Text = ev.Glyph ?? "";
            ActivityTitle.Text = ev.Title ?? "";
            ActivityValue.Text = ev.Value ?? "";
            if (ev.Tint.HasValue)
            {
                var b = Frozen(ev.Tint.Value);
                ActivityGlyph.Foreground = b;
                ActivityValue.Foreground = b;
            }
            else
            {
                ActivityGlyph.SetResourceReference(TextBlock.ForegroundProperty, "AccentBrush");
                ActivityValue.SetResourceReference(TextBlock.ForegroundProperty, "AccentBrush");
            }

            _activityActive = true;
            GoTo(IslandState.Activity);

            _activityTimer.Stop();
            _activityTimer.Interval = TimeSpan.FromSeconds(Math.Max(0.8, ev.Seconds));
            _activityTimer.Start();
        }

        void EndActivity()
        {
            _activityTimer.Stop();
            if (!_activityActive) return;
            _activityActive = false;
            if (_state == IslandState.Activity) GoTo(_hover ? IslandState.Expanded : IslandState.Compact);
        }

        void ShowNextNotification()
        {
            if (_queue.Count == 0)
            {
                _notificationActive = false;
                GoTo(_hover ? IslandState.Expanded : IslandState.Compact);
                return;
            }

            var n = _queue.Dequeue();
            _notificationActive = true;
            _activityActive = false;
            _activityTimer.Stop();

            NotifApp.Text = n.AppName ?? "";
            NotifTitle.Text = n.Title ?? "";
            NotifBody.Text = n.Body ?? "";
            NotifBody.Visibility = string.IsNullOrEmpty(n.Body) ? Visibility.Collapsed : Visibility.Visible;

            var icon = ImageHelper.FromBytes(n.IconBytes, 64);
            NotifIconBrush.ImageSource = icon;
            NotifIconImg.Visibility = icon == null ? Visibility.Collapsed : Visibility.Visible;
            NotifGlyph.Visibility = icon == null ? Visibility.Visible : Visibility.Collapsed;
            NotifGlyph.Text = n.IsTelegram ? "\uE724" : "\uEA8F";
            if (n.IsTelegram) NotifGlyph.Foreground = Frozen(Color.FromRgb(0x2A, 0xAB, 0xEE));
            else NotifGlyph.SetResourceReference(TextBlock.ForegroundProperty, "AccentBrush");

            GoTo(IslandState.Notification);

            _notifTimer.Stop();
            _notifTimer.Interval = TimeSpan.FromSeconds(Math.Max(2, App.Settings.NotificationSeconds));
            _notifTimer.Start();
        }

        void Notification_Click(object sender, MouseButtonEventArgs e)
        {
            _notifTimer.Stop();
            ShowNextNotification();
        }

        // ------------------------------------------------------------------ win32

        const int GWL_EXSTYLE = -20;
        const int WS_EX_TOOLWINDOW = 0x00000080;
        const int WS_EX_NOACTIVATE = 0x08000000;
        const int WS_EX_TRANSPARENT = 0x00000020;
        const int WS_EX_LAYERED = 0x00080000;
        const int VK_LBUTTON = 0x01, VK_RBUTTON = 0x02;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010, SWP_NOOWNERZORDER = 0x0200;
        const uint EVENT_SYSTEM_FOREGROUND = 0x0003, EVENT_SYSTEM_SWITCHEND = 0x0015, EVENT_SYSTEM_MINIMIZEEND = 0x0017;
        const uint WINEVENT_OUTOFCONTEXT = 0x0000;

        delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        struct POINT { public int X, Y; }

        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT pt);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmod, WinEventDelegate proc, uint idProcess, uint idThread, uint flags);
        [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);

        void MakeToolWindow()
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            int ex = GetWindowLong(_hwnd, GWL_EXSTYLE);
            SetWindowLong(_hwnd, GWL_EXSTYLE, ex | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
        }

        /// <summary>Вернуть окно на самый верхний слой без активации (после Alt+Tab, разворачивания окон и т.д.).</summary>
        void KeepOnTop()
        {
            if (_hwnd == IntPtr.Zero || !App.Settings.AlwaysOnTop || !IsVisible) return;
            SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        }

        // ------------------------------------------------------------------ клики сквозь остров

        /// <summary>Курсор над островом? p — координаты курсора внутри Island.</summary>
        bool TryGetIslandPoint(out Point p)
        {
            p = default;
            if (!Island.IsVisible || Root.Visibility != Visibility.Visible) return false;
            if (PresentationSource.FromVisual(Island) == null) return false;
            if (!GetCursorPos(out var pt)) return false;
            try { p = Island.PointFromScreen(new Point(pt.X, pt.Y)); }
            catch (InvalidOperationException) { return false; }
            return p.X >= 0 && p.Y >= 0 && p.X <= Island.ActualWidth && p.Y <= Island.ActualHeight;
        }

        /// <summary>
        /// Под курсором что-то нажимаемое: кнопка, переключатель, ползунок, строка недавних
        /// треков или уведомление (всё, у чего курсор-«рука»).
        /// </summary>
        bool IsInteractiveAt(Point p)
        {
            DependencyObject hit = null;
            try
            {
                VisualTreeHelper.HitTest(Island, null, r =>
                {
                    hit = r.VisualHit;
                    return HitTestResultBehavior.Stop;
                }, new PointHitTestParameters(p));
            }
            catch { return false; }

            for (var d = hit; d != null && !ReferenceEquals(d, Island); d = ParentOf(d))
            {
                if (d is System.Windows.Controls.Primitives.ButtonBase
                    || d is Slider
                    || d is System.Windows.Controls.Primitives.Thumb
                    || d is TextBox) return true;
                if (d is FrameworkElement fe && fe.Cursor == Cursors.Hand) return true;
            }
            return false;
        }

        static DependencyObject ParentOf(DependencyObject d)
            => d is Visual || d is System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(d)
                : LogicalTreeHelper.GetParent(d);

        /// <summary>
        /// «Клики сквозь остров»: окно пропускает мышь к тому, что под ним, и
        /// перехватывает её только когда курсор над кнопкой (или идёт перетаскивание ползунка).
        /// Наведение для раскрытия острова считаем сами — в сквозном режиме WPF его не видит.
        /// </summary>
        void UpdatePassThrough()
        {
            if (_hwnd == IntPtr.Zero) return;
            if (!App.Settings.ClickThrough) { SetPassThrough(false); return; }

            bool over = TryGetIslandPoint(out var p);
            bool onButton = over && IsInteractiveAt(p);
            bool mouseDown = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0
                          || (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;

            // если нажали на кнопку и повели мышь — не отпускаем окно до конца нажатия
            bool interactive = _menuOpen || _dragging || _volDragging || onButton || (!_passThrough && mouseDown && over);
            SetPassThrough(!interactive);

            if (over && !_hover) Island_MouseEnter(Island, null);
            else if (!over && _hover && !_dragging && !_volDragging && !_menuOpen) Island_MouseLeave(Island, null);
        }

        void SetPassThrough(bool on)
        {
            if (on == _passThrough) return;
            _passThrough = on;
            int ex = GetWindowLong(_hwnd, GWL_EXSTYLE);
            ex = on ? ex | WS_EX_TRANSPARENT | WS_EX_LAYERED : ex & ~WS_EX_TRANSPARENT;
            SetWindowLong(_hwnd, GWL_EXSTYLE, ex);
        }

        void HookForeground()
        {
            _winEventProc = OnWinEvent; // держим ссылку, чтобы делегат не собрал GC
            _winHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MINIMIZEEND, IntPtr.Zero, _winEventProc, 0, 0, WINEVENT_OUTOFCONTEXT);
        }

        void OnWinEvent(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (eventType != EVENT_SYSTEM_FOREGROUND && eventType != EVENT_SYSTEM_SWITCHEND && eventType != EVENT_SYSTEM_MINIMIZEEND) return;
            KeepOnTop();
            Dispatcher.BeginInvoke(new Action(() => { CheckFullscreen(); KeepOnTop(); }), DispatcherPriority.Background);
        }

        void CheckFullscreen()
        {
            if (!App.Settings.HideInFullscreen) return;
            bool full = false;
            try
            {
                var fg = GetForegroundWindow();
                if (fg != IntPtr.Zero && fg != _hwnd && fg != GetDesktopWindow() && fg != GetShellWindow())
                {
                    var sb = new StringBuilder(256);
                    GetClassName(fg, sb, 256);
                    var cls = sb.ToString();
                    if (cls != "WorkerW" && cls != "Progman" && GetWindowRect(fg, out var r))
                    {
                        var screen = System.Windows.Forms.Screen.FromHandle(fg).Bounds;
                        full = r.Left <= screen.Left && r.Top <= screen.Top && r.Right >= screen.Right && r.Bottom >= screen.Bottom;
                    }
                }
            }
            catch { }
            Root.Visibility = full ? Visibility.Hidden : Visibility.Visible;
        }
    }
}
