using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace DynamicIsland
{
    /// <summary>
    /// Работает через системные медиа-элементы Windows (то же, что показывает
    /// всплывающее окно громкости). Ловит Spotify, Яндекс Музыку, YouTube в
    /// Chrome/Edge/Firefox/Opera, Telegram, VLC, AIMP и т.д.
    /// </summary>
    public class MediaService
    {
        GlobalSystemMediaTransportControlsSessionManager _manager;
        GlobalSystemMediaTransportControlsSession _session;

        TimeSpan _position;
        DateTimeOffset _positionUpdated;
        DateTimeOffset _lastTimelineStamp;
        double _rate = 1;

        public TrackInfo Current { get; private set; }
        public event Action TrackChanged;
        public event Action PlaybackChanged;

        public async Task InitAsync()
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _manager.CurrentSessionChanged += (s, e) => AttachSession();
            _manager.SessionsChanged += (s, e) => AttachSession();
            AttachSession();
        }

        void AttachSession()
        {
            GlobalSystemMediaTransportControlsSession next = null;
            try
            {
                next = _manager.GetCurrentSession() ?? _manager.GetSessions().FirstOrDefault();
            }
            catch (Exception ex) { Debug.WriteLine(ex); }

            if (next != null && _session != null && next.SourceAppUserModelId == _session.SourceAppUserModelId && ReferenceEquals(next, _session))
                return;

            if (_session != null)
            {
                _session.MediaPropertiesChanged -= OnMediaProperties;
                _session.PlaybackInfoChanged -= OnPlaybackInfo;
                _session.TimelinePropertiesChanged -= OnTimeline;
            }

            _session = next;
            if (_session == null)
            {
                Current = null;
                TrackChanged?.Invoke();
                return;
            }

            _session.MediaPropertiesChanged += OnMediaProperties;
            _session.PlaybackInfoChanged += OnPlaybackInfo;
            _session.TimelinePropertiesChanged += OnTimeline;
            _lastTimelineStamp = default;
            _ = RefreshPropertiesAsync();
        }

        void OnMediaProperties(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs e) => _ = RefreshPropertiesAsync();

        void OnPlaybackInfo(GlobalSystemMediaTransportControlsSession s, PlaybackInfoChangedEventArgs e)
        {
            RefreshPlayback();
            PlaybackChanged?.Invoke();
        }

        void OnTimeline(GlobalSystemMediaTransportControlsSession s, TimelinePropertiesChangedEventArgs e) => RefreshTimeline();

        async Task RefreshPropertiesAsync()
        {
            var session = _session;
            if (session == null) return;
            try
            {
                var p = await session.TryGetMediaPropertiesAsync();
                if (p == null || session != _session || string.IsNullOrWhiteSpace(p.Title)) return;

                var track = new TrackInfo
                {
                    Title = p.Title,
                    Artist = string.IsNullOrWhiteSpace(p.Artist) ? p.AlbumArtist : p.Artist,
                    Album = p.AlbumTitle,
                    SourceAppId = session.SourceAppUserModelId,
                    IsPlaying = Current?.IsPlaying ?? false
                };

                if (p.Thumbnail != null)
                    track.CoverBytes = await ReadAllAsync(p.Thumbnail);

                bool newTrack = Current == null || Current.Key != track.Key;
                if (!newTrack && track.CoverBytes == null) track.CoverBytes = Current.CoverBytes;

                Current = track;
                if (newTrack) _lastTimelineStamp = default;
                RefreshPlayback();
                RefreshTimeline();
                TrackChanged?.Invoke();
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
        }

        void RefreshPlayback()
        {
            var s = _session;
            var t = Current;
            if (s == null || t == null) return;
            try
            {
                var info = s.GetPlaybackInfo();
                bool playing = info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
                if (playing != t.IsPlaying)
                {
                    // фиксируем текущую позицию в момент смены паузы/воспроизведения
                    _position = GetPosition();
                    _positionUpdated = DateTimeOffset.Now;
                }
                t.IsPlaying = playing;
                _rate = info.PlaybackRate ?? 1;
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
        }

        void RefreshTimeline()
        {
            var s = _session;
            var t = Current;
            if (s == null || t == null) return;
            try
            {
                var tl = s.GetTimelineProperties();
                var duration = tl.EndTime - tl.StartTime;
                if (duration > TimeSpan.Zero) t.Duration = duration;
                if (tl.LastUpdatedTime != _lastTimelineStamp)
                {
                    _lastTimelineStamp = tl.LastUpdatedTime;
                    _position = tl.Position - tl.StartTime;
                    _positionUpdated = tl.LastUpdatedTime;
                }
            }
            catch (Exception ex) { Debug.WriteLine(ex); }
        }

        public TimeSpan GetPosition()
        {
            var t = Current;
            if (t == null) return TimeSpan.Zero;
            var p = _position;
            if (t.IsPlaying && _positionUpdated != default)
                p += TimeSpan.FromSeconds((DateTimeOffset.Now - _positionUpdated).TotalSeconds * _rate);
            if (t.Duration > TimeSpan.Zero && p > t.Duration) p = t.Duration;
            if (p < TimeSpan.Zero) p = TimeSpan.Zero;
            return p;
        }

        public async Task PlayPauseAsync()
        {
            try { if (_session != null) await _session.TryTogglePlayPauseAsync(); } catch (Exception ex) { Debug.WriteLine(ex); }
        }

        public async Task NextAsync()
        {
            try { if (_session != null) await _session.TrySkipNextAsync(); } catch (Exception ex) { Debug.WriteLine(ex); }
        }

        public async Task PreviousAsync()
        {
            try { if (_session != null) await _session.TrySkipPreviousAsync(); } catch (Exception ex) { Debug.WriteLine(ex); }
        }

        public async Task SeekAsync(TimeSpan position)
        {
            _position = position;
            _positionUpdated = DateTimeOffset.Now;
            try { if (_session != null) await _session.TryChangePlaybackPositionAsync(position.Ticks); } catch (Exception ex) { Debug.WriteLine(ex); }
        }

        static async Task<byte[]> ReadAllAsync(IRandomAccessStreamReference reference)
        {
            try
            {
                using var ras = await reference.OpenReadAsync();
                using var stream = ras.AsStreamForRead();
                using var ms = new MemoryStream();
                await stream.CopyToAsync(ms);
                return ms.ToArray();
            }
            catch
            {
                return null;
            }
        }
    }
}
