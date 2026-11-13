using System;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DynamicIsland
{
    public static class ImageHelper
    {
        public static BitmapImage FromBytes(byte[] bytes, int decodeWidth = 0)
        {
            if (bytes == null || bytes.Length == 0) return null;
            try
            {
                var img = new BitmapImage();
                img.BeginInit();
                img.CacheOption = BitmapCacheOption.OnLoad;
                img.StreamSource = new MemoryStream(bytes);
                if (decodeWidth > 0) img.DecodePixelWidth = decodeWidth;
                img.EndInit();
                img.Freeze();
                return img;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>Средний цвет обложки, осветлённый — для акцентов (эквалайзер, прогресс).</summary>
        public static Color? AverageColor(BitmapSource src)
        {
            try
            {
                if (src == null || src.PixelWidth == 0 || src.PixelHeight == 0) return null;
                var scaled = new TransformedBitmap(src, new ScaleTransform(8.0 / src.PixelWidth, 8.0 / src.PixelHeight));
                var conv = new FormatConvertedBitmap(scaled, PixelFormats.Bgra32, null, 0);
                int w = conv.PixelWidth, h = conv.PixelHeight;
                var px = new byte[w * h * 4];
                conv.CopyPixels(px, w * 4, 0);

                double r = 0, g = 0, b = 0;
                int n = 0;
                for (int i = 0; i < px.Length; i += 4)
                {
                    b += px[i]; g += px[i + 1]; r += px[i + 2]; n++;
                }
                if (n == 0) return null;
                r /= n; g /= n; b /= n;

                double max = Math.Max(r, Math.Max(g, b));
                if (max < 1) return Colors.White;
                double k = 235.0 / max;
                return Color.FromRgb((byte)Math.Min(255, r * k), (byte)Math.Min(255, g * k), (byte)Math.Min(255, b * k));
            }
            catch
            {
                return null;
            }
        }
    }
}
