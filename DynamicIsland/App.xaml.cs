using System;
using System.Threading;
using System.Windows;
using Microsoft.Win32;

namespace DynamicIsland
{
    public partial class App : Application
    {
        public const string Author = "@vvassuup";
        public const string CreatedBy = "created by @vvassuup";
        public const string TelegramUrl = "https://t.me/vvassuup";

        /// <summary>Открыть Telegram автора в браузере / приложении.</summary>
        public static void OpenTelegram()
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(TelegramUrl) { UseShellExecute = true }); }
            catch { }
        }

        public static AppSettings Settings { get; private set; } = new AppSettings();
        public static event Action SettingsChanged;

        static App _instance;
        Mutex _mutex;
        MainWindow _main;
        SettingsWindow _settingsWindow;
        System.Windows.Forms.NotifyIcon _tray;
        System.Windows.Forms.ToolStripMenuItem _settingsItem, _dndItem, _passItem, _toggleItem, _testItem, _langItem, _exitItem;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            _mutex = new Mutex(true, "DynamicIsland_SingleInstance_Mutex", out bool created);
            if (!created)
            {
                Shutdown();
                return;
            }

            _instance = this;
            Settings = AppSettings.Load();

            // Язык: выбранный в установщике → сохранённый в настройках → язык Windows.
            var fromInstaller = Loc.ConsumeInstallerLanguage();
            if (fromInstaller != null) Settings.Language = fromInstaller;
            if (Loc.Normalize(Settings.Language) == null) Settings.Language = Loc.SystemDefault();
            Loc.Apply(Settings.Language);
            Settings.Save();

            _main = new MainWindow();
            _main.Show();

            CreateTray();
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        }

        // ------------------------------------------------------------------ трей

        void CreateTray()
        {
            _tray = new System.Windows.Forms.NotifyIcon
            {
                Icon = LoadTrayIcon(),
                Text = "Dynamic Island — " + CreatedBy,
                Visible = true
            };

            var menu = new System.Windows.Forms.ContextMenuStrip();

            _settingsItem = new System.Windows.Forms.ToolStripMenuItem();
            _settingsItem.Click += (s, e) => ShowSettings();
            menu.Items.Add(_settingsItem);

            _dndItem = new System.Windows.Forms.ToolStripMenuItem { CheckOnClick = true };
            _dndItem.Click += (s, e) =>
            {
                Settings.DoNotDisturb = _dndItem.Checked;
                RaiseSettingsChanged();
            };
            menu.Items.Add(_dndItem);

            _passItem = new System.Windows.Forms.ToolStripMenuItem { CheckOnClick = true };
            _passItem.Click += (s, e) =>
            {
                Settings.ClickThrough = _passItem.Checked;
                RaiseSettingsChanged();
            };
            menu.Items.Add(_passItem);

            _langItem = new System.Windows.Forms.ToolStripMenuItem();
            foreach (var (id, name) in Loc.Languages)
            {
                var item = new System.Windows.Forms.ToolStripMenuItem(name) { Tag = id };
                item.Click += (s, e) => SetLanguage(id);
                _langItem.DropDownItems.Add(item);
            }
            menu.Items.Add(_langItem);

            _toggleItem = new System.Windows.Forms.ToolStripMenuItem();
            _toggleItem.Click += (s, e) =>
            {
                if (_main.IsVisible) _main.Hide(); else _main.Show();
            };
            menu.Items.Add(_toggleItem);

            _testItem = new System.Windows.Forms.ToolStripMenuItem();
            _testItem.Click += (s, e) => TestNotification();
            menu.Items.Add(_testItem);

            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add(new System.Windows.Forms.ToolStripMenuItem(CreatedBy) { Enabled = false });
            menu.Items.Add(new System.Windows.Forms.ToolStripMenuItem("t.me/vvassuup", null, (s, e) => OpenTelegram()));

            _exitItem = new System.Windows.Forms.ToolStripMenuItem();
            _exitItem.Click += (s, e) =>
            {
                _tray.Visible = false;
                Shutdown();
            };
            menu.Items.Add(_exitItem);

            menu.Opening += (s, e) =>
            {
                _dndItem.Checked = Settings.DoNotDisturb;
                _passItem.Checked = Settings.ClickThrough;
                foreach (System.Windows.Forms.ToolStripMenuItem li in _langItem.DropDownItems)
                    li.Checked = (string)li.Tag == Loc.Lang;
            };

            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (s, e) => ShowSettings();
            UpdateTrayTexts();
        }

        void UpdateTrayTexts()
        {
            if (_tray == null) return;
            _settingsItem.Text = Loc.T("tray_settings");
            _dndItem.Text = Loc.T("tray_dnd");
            _passItem.Text = Loc.T("tray_clickthrough");
            _langItem.Text = Loc.T("tray_language") + " / Language";
            _toggleItem.Text = Loc.T("tray_toggle");
            _testItem.Text = Loc.T("tray_test");
            _exitItem.Text = Loc.T("tray_exit");
        }

        /// <summary>Светлая панель задач → тёмная иконка, тёмная панель → белая.</summary>
        static System.Drawing.Icon LoadTrayIcon()
        {
            string file = IsTaskbarLight() ? "tray-dark.ico" : "tray-light.ico";
            try
            {
                var info = GetResourceStream(new Uri("pack://application:,,,/Assets/" + file));
                if (info != null)
                {
                    using (var s = info.Stream)
                        return new System.Drawing.Icon(s, System.Windows.Forms.SystemInformation.SmallIconSize);
                }
            }
            catch { }
            return System.Drawing.SystemIcons.Application;
        }

        static bool IsTaskbarLight()
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
            }
            catch { return false; }
        }

        void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (e.Category != UserPreferenceCategory.General && e.Category != UserPreferenceCategory.VisualStyle) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (_tray == null) return;
                var old = _tray.Icon;
                _tray.Icon = LoadTrayIcon();
                if (old != null && !ReferenceEquals(old, System.Drawing.SystemIcons.Application)) old.Dispose();
            }));
        }

        // ------------------------------------------------------------------ настройки

        public static void RaiseSettingsChanged()
        {
            Settings.Save();
            SettingsChanged?.Invoke();
        }

        /// <summary>Сменить язык интерфейса на лету (остров, настройки, трей).</summary>
        public static void SetLanguage(string lang)
        {
            Settings.Language = Loc.Normalize(lang) ?? "en";
            Loc.Apply(Settings.Language);
            _instance?.UpdateTrayTexts();
            _instance?._settingsWindow?.OnLanguageChanged();
            RaiseSettingsChanged();
        }

        public static void ShowSettings()
        {
            if (_instance == null) return;
            if (_instance._settingsWindow == null)
            {
                _instance._settingsWindow = new SettingsWindow();
                _instance._settingsWindow.Closed += (s, e) => _instance._settingsWindow = null;
                _instance._settingsWindow.Show();
            }
            _instance._settingsWindow.Activate();
        }

        public static void TestNotification()
        {
            byte[] icon = null;
            try { icon = AppIconResolver.Resolve("Telegram", null); } catch { }
            if (icon == null)
            {
                try
                {
                    var p = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Telegram Desktop", "Telegram.exe");
                    if (System.IO.File.Exists(p)) icon = AppIconResolver.Resolve("Telegram", p);
                }
                catch { }
            }

            _instance?._main?.EnqueueNotification(new NotificationItem
            {
                AppName = "Telegram",
                IconBytes = icon,
                Title = Loc.T("test_title"),
                Body = Loc.T("test_body"),
                IsTelegram = true,
                Force = true
            });
        }

        protected override void OnExit(ExitEventArgs e)
        {
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            if (_tray != null)
            {
                _tray.Visible = false;
                _tray.Dispose();
            }
            base.OnExit(e);
        }
    }
}
