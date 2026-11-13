using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Windows.UI.Notifications;
using Windows.UI.Notifications.Management;

namespace DynamicIsland
{
    /// <summary>
    /// Читает уведомления из Центра уведомлений Windows.
    /// Telegram Desktop попадает сюда, если в нём включены системные уведомления.
    /// </summary>
    public class NotificationService
    {
        UserNotificationListener _listener;
        readonly HashSet<uint> _seen = new HashSet<uint>();
        Timer _timer;
        int _busy;

        public event Action<NotificationItem> NotificationReceived;

        public async Task<bool> InitAsync()
        {
            try
            {
                _listener = UserNotificationListener.Current;
                var status = await _listener.RequestAccessAsync();
                if (status != UserNotificationListenerAccessStatus.Allowed) return false;

                var existing = await _listener.GetNotificationsAsync(NotificationKinds.Toast);
                foreach (var n in existing) _seen.Add(n.Id);

                _timer = new Timer(_ => Poll(), null, 1000, 800);
                return true;
            }
            catch (Exception ex)
            {
                Debug.WriteLine(ex);
                return false;
            }
        }

        async void Poll()
        {
            if (Interlocked.Exchange(ref _busy, 1) == 1) return;
            try
            {
                var list = await _listener.GetNotificationsAsync(NotificationKinds.Toast);
                var ids = new HashSet<uint>();
                foreach (var n in list)
                {
                    ids.Add(n.Id);
                    if (_seen.Contains(n.Id)) continue;
                    _seen.Add(n.Id);
                    var item = await ParseAsync(n);
                    if (item != null) NotificationReceived?.Invoke(item);
                }
                _seen.IntersectWith(ids);
            }
            catch (Exception ex)
            {
                Debug.WriteLine(ex);
            }
            finally
            {
                Interlocked.Exchange(ref _busy, 0);
            }
        }

        static async Task<NotificationItem> ParseAsync(UserNotification n)
        {
            string app = "Windows";
            byte[] icon = null;

            string aumid = null;
            try { app = n.AppInfo.DisplayInfo.DisplayName; } catch { }
            try { aumid = n.AppInfo.AppUserModelId; } catch { }

            // настоящая иконка из exe (Telegram, Discord…): Windows для них отдаёт серую заглушку
            try { icon = AppIconResolver.Resolve(app, aumid); } catch { }

            if (icon == null)
            try
            {
                var logo = n.AppInfo.DisplayInfo.GetLogo(new Windows.Foundation.Size(64, 64));
                using var ras = await logo.OpenReadAsync();
                using var s = ras.AsStreamForRead();
                using var ms = new MemoryStream();
                await s.CopyToAsync(ms);
                icon = ms.ToArray();
            }
            catch { }

            string title = "", body = "";
            try
            {
                var binding = n.Notification.Visual.GetBinding(KnownNotificationBindings.ToastGeneric);
                if (binding != null)
                {
                    var texts = binding.GetTextElements()
                        .Select(t => t.Text)
                        .Where(t => !string.IsNullOrWhiteSpace(t))
                        .ToList();
                    if (texts.Count > 0) title = texts[0];
                    if (texts.Count > 1) body = string.Join("\n", texts.Skip(1));
                }
            }
            catch { }

            if (string.IsNullOrWhiteSpace(title) && string.IsNullOrWhiteSpace(body)) return null;

            var lower = ((app ?? "") + " " + (aumid ?? "")).ToLowerInvariant();
            bool isTelegram = lower.Contains("telegram") || lower.Contains("ayugram") || lower.Contains("kotatogram") || lower.Contains("64gram");

            return new NotificationItem
            {
                AppName = app,
                Title = title,
                Body = body,
                IconBytes = icon,
                IsTelegram = isTelegram
            };
        }
    }
}
