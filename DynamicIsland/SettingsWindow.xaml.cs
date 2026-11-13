using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace DynamicIsland
{
    public partial class SettingsWindow : Window
    {
        bool _loading = true;
        static readonly SolidColorBrush SelectedRing = new SolidColorBrush(Colors.White);

        public SettingsWindow()
        {
            InitializeComponent();
            BuildPlatformChips();
            BuildLanguageChips();
            VersionText.Text = "Dynamic Island " + AppVersion();

            var s = App.Settings;
            ScaleSlider.Value = s.Scale;
            OffsetSlider.Value = s.TopOffset;
            OpacitySlider.Value = Math.Round(Math.Max(0.15, Math.Min(1, s.IslandOpacity)) * 100);
            DurationSlider.Value = s.NotificationSeconds;
            ColorBox.Text = (s.IslandColor ?? "#000000").ToUpperInvariant();
            GradientBox.Text = (s.GradientColor ?? "#FF375F").ToUpperInvariant();
            BgSolid.IsChecked = s.BackgroundStyle != "cover" && s.BackgroundStyle != "custom";
            BgCover.IsChecked = s.BackgroundStyle == "cover";
            BgCustom.IsChecked = s.BackgroundStyle == "custom";

            ShadowBox.IsChecked = s.Shadow;
            VinylBox.IsChecked = s.VinylCover;
            GlowBox.IsChecked = s.CoverGlow;
            AccentCoverBox.IsChecked = s.AccentFromCover;
            VolumeBox.IsChecked = s.ShowVolume;
            LyricsBox.IsChecked = s.ShowLyrics;
            CompactLyricsBox.IsChecked = s.CompactLyrics;
            ClockBox.IsChecked = s.ShowClock;
            WinNotifBox.IsChecked = s.WindowsNotifications;
            TgNotifBox.IsChecked = s.TelegramNotifications;
            DndBox.IsChecked = s.DoNotDisturb;
            TopBox.IsChecked = s.AlwaysOnTop;
            FullscreenBox.IsChecked = s.HideInFullscreen;
            AutoStartBox.IsChecked = AutoStart.IsEnabled();
            ClickThroughBox.IsChecked = s.ClickThrough;
            EvLayoutBox.IsChecked = s.ShowLayoutChange;
            EvPowerBox.IsChecked = s.ShowCharging;
            EvBtBox.IsChecked = s.ShowBluetooth;

            UpdateLabels();
            UpdatePreview();
            _loading = false;
        }

        void BuildPlatformChips()
        {
            AddChip("auto", Loc.T("set_auto"));
            foreach (var p in Platforms.All) AddChip(p.Id, p.Name);
        }

        void BuildLanguageChips()
        {
            LangPanel.Children.Clear();
            foreach (var (id, name) in Loc.Languages)
            {
                var rb = new RadioButton
                {
                    Content = name,
                    Tag = id,
                    GroupName = "lang",
                    Style = (Style)FindResource("Chip"),
                    IsChecked = id == Loc.Lang
                };
                rb.Checked += (s, e) =>
                {
                    if (_loading) return;
                    App.SetLanguage(id);
                };
                LangPanel.Children.Add(rb);
            }
        }

        /// <summary>Вызывается из App.SetLanguage — обновляет то, что задано из кода.</summary>
        public void OnLanguageChanged()
        {
            bool was = _loading;
            _loading = true;
            PlatformPanel.Children.Clear();
            BuildPlatformChips();
            foreach (var child in LangPanel.Children)
                if (child is RadioButton rb) rb.IsChecked = (string)rb.Tag == Loc.Lang;
            UpdateLabels();
            _loading = was;
        }

        static string AppVersion()
        {
            var v = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
            return v == null ? "" : $"v{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
        }

        void AddChip(string id, string name)
        {
            var current = string.IsNullOrEmpty(App.Settings.RecentPlatform) ? "auto" : App.Settings.RecentPlatform;
            var rb = new RadioButton
            {
                Content = name,
                Tag = id,
                GroupName = "platform",
                Style = (Style)FindResource("Chip"),
                IsChecked = id == current
            };
            rb.Checked += (s, e) =>
            {
                if (_loading) return;
                App.Settings.RecentPlatform = id;
                App.RaiseSettingsChanged();
            };
            PlatformPanel.Children.Add(rb);
        }

        // ------------------------------------------------------------------ подписи и превью

        void UpdateLabels()
        {
            ScaleValue.Text = Math.Round(ScaleSlider.Value * 100) + "%";
            OffsetValue.Text = (int)OffsetSlider.Value + " px";
            OpacityValue.Text = (int)OpacitySlider.Value + "%";
            DurationValue.Text = (int)DurationSlider.Value + Loc.T("unit_sec");
            AccentSwatches.IsEnabled = AccentCoverBox.IsChecked != true;
            AccentSwatches.Opacity = AccentSwatches.IsEnabled ? 1 : 0.35;
            CompactLyricsBox.IsEnabled = LyricsBox.IsChecked == true;
            GradientPanel.IsEnabled = App.Settings.BackgroundStyle == "custom";
            GradientPanel.Opacity = GradientPanel.IsEnabled ? 1 : 0.35;
        }

        void UpdatePreview()
        {
            var s = App.Settings;
            var c = ColorUtil.Parse(s.IslandColor, Colors.Black);
            byte alpha = (byte)Math.Round(255 * Math.Max(0.15, Math.Min(1, s.IslandOpacity)));
            if (s.BackgroundStyle == "cover" || s.BackgroundStyle == "custom")
            {
                // для превью «Градиент трека» берём тёплый пример цвета обложки
                var tint = s.BackgroundStyle == "cover" ? Color.FromRgb(0xC8, 0x90, 0x6A) : ColorUtil.Parse(s.GradientColor, Color.FromRgb(0xFF, 0x37, 0x5F));
                PreviewPill.Background = ColorUtil.MakeGradient(ColorUtil.GradientColors(c, tint, alpha));
            }
            else
            {
                c.A = alpha;
                PreviewPill.Background = new SolidColorBrush(c);
            }

            var accent = s.AccentFromCover ? Color.FromRgb(0xFF, 0x9F, 0x0A) : ColorUtil.Parse(s.AccentColor, Colors.White);
            PreviewDot.Fill = new SolidColorBrush(accent);

            Mark(ColorSwatches, s.IslandColor);
            Mark(AccentSwatches, s.AccentFromCover ? null : s.AccentColor);
            Mark(GradientSwatches, s.BackgroundStyle == "custom" ? s.GradientColor : null);
        }

        static void Mark(Panel panel, string hex)
        {
            foreach (var child in panel.Children)
            {
                if (child is Button b)
                {
                    bool on = hex != null && string.Equals(b.Tag as string, hex, StringComparison.OrdinalIgnoreCase);
                    b.BorderBrush = on ? SelectedRing : Brushes.Transparent;
                }
            }
        }

        // ------------------------------------------------------------------ обработчики

        void SliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_loading) return;
            Apply();
        }

        void Changed(object sender, RoutedEventArgs e)
        {
            if (_loading) return;
            Apply();
        }

        void Swatch_Click(object sender, RoutedEventArgs e)
        {
            if (!((sender as Button)?.Tag is string hex)) return;
            ColorBox.Text = hex;
            App.Settings.IslandColor = hex;
            Apply();
        }

        void Accent_Click(object sender, RoutedEventArgs e)
        {
            if (!((sender as Button)?.Tag is string hex)) return;
            App.Settings.AccentColor = hex;
            Apply();
        }

        void BgMode_Checked(object sender, RoutedEventArgs e)
        {
            if (_loading) return;
            if ((sender as RadioButton)?.Tag is string mode)
            {
                App.Settings.BackgroundStyle = mode;
                Apply();
            }
        }

        void Gradient_Click(object sender, RoutedEventArgs e)
        {
            if (!((sender as Button)?.Tag is string hex)) return;
            GradientBox.Text = hex;
            App.Settings.GradientColor = hex;
            Apply();
        }

        void GradientBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter) { CommitGradient(); e.Handled = true; }
        }

        void GradientBox_LostFocus(object sender, RoutedEventArgs e) => CommitGradient();

        void CommitGradient()
        {
            if (_loading) return;
            var text = (GradientBox.Text ?? "").Trim();
            if (!text.StartsWith("#")) text = "#" + text;
            if (ColorUtil.TryParse(text, out var c))
            {
                var hex = $"#{c.R:X2}{c.G:X2}{c.B:X2}";
                GradientBox.Text = hex;
                App.Settings.GradientColor = hex;
                Apply();
            }
            else
            {
                GradientBox.Text = App.Settings.GradientColor;
            }
        }

        void Telegram_Click(object sender, MouseButtonEventArgs e) => App.OpenTelegram();

        void ColorBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter) { CommitColor(); e.Handled = true; }
        }

        void ColorBox_LostFocus(object sender, RoutedEventArgs e) => CommitColor();

        void CommitColor()
        {
            if (_loading) return;
            var text = (ColorBox.Text ?? "").Trim();
            if (!text.StartsWith("#")) text = "#" + text;
            if (ColorUtil.TryParse(text, out var c))
            {
                var hex = $"#{c.R:X2}{c.G:X2}{c.B:X2}";
                ColorBox.Text = hex;
                App.Settings.IslandColor = hex;
                Apply();
            }
            else
            {
                ColorBox.Text = App.Settings.IslandColor;
            }
        }

        void Apply()
        {
            var s = App.Settings;
            s.Scale = Math.Round(ScaleSlider.Value, 2);
            s.TopOffset = Math.Round(OffsetSlider.Value);
            s.IslandOpacity = Math.Round(OpacitySlider.Value) / 100.0;
            s.NotificationSeconds = Math.Round(DurationSlider.Value);
            s.Shadow = ShadowBox.IsChecked == true;
            s.VinylCover = VinylBox.IsChecked == true;
            s.CoverGlow = GlowBox.IsChecked == true;
            s.AccentFromCover = AccentCoverBox.IsChecked == true;
            s.ShowVolume = VolumeBox.IsChecked == true;
            s.ShowLyrics = LyricsBox.IsChecked == true;
            s.CompactLyrics = CompactLyricsBox.IsChecked == true;
            s.ShowClock = ClockBox.IsChecked == true;
            s.WindowsNotifications = WinNotifBox.IsChecked == true;
            s.TelegramNotifications = TgNotifBox.IsChecked == true;
            s.DoNotDisturb = DndBox.IsChecked == true;
            s.AlwaysOnTop = TopBox.IsChecked == true;
            s.HideInFullscreen = FullscreenBox.IsChecked == true;
            s.ClickThrough = ClickThroughBox.IsChecked == true;
            s.ShowLayoutChange = EvLayoutBox.IsChecked == true;
            s.ShowCharging = EvPowerBox.IsChecked == true;
            s.ShowBluetooth = EvBtBox.IsChecked == true;
            UpdateLabels();
            UpdatePreview();
            App.RaiseSettingsChanged();
        }

        void AutoStart_Changed(object sender, RoutedEventArgs e)
        {
            if (_loading) return;
            AutoStart.Set(AutoStartBox.IsChecked == true);
        }

        void Header_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ButtonState == MouseButtonState.Pressed)
            {
                try { DragMove(); } catch (InvalidOperationException) { }
            }
        }

        void Window_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Escape && !ColorBox.IsKeyboardFocused && !GradientBox.IsKeyboardFocused) Close();
        }

        void Test_Click(object sender, RoutedEventArgs e) => App.TestNotification();

        void Close_Click(object sender, RoutedEventArgs e) => Close();
    }
}
