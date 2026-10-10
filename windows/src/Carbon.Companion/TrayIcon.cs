using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace Carbon.Companion;

/// <summary>The tray icon (SPEC 6.7): a dot-matrix "C". Left-click opens the panel.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon icon;
    private readonly Icon image;

    public TrayIcon(Action onOpen, Action onQuit)
    {
        image = DotMatrixC();
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open CARBON", null, (_, _) => onOpen());
        menu.Items.Add("Quit", null, (_, _) => onQuit());
        icon = new Forms.NotifyIcon { Icon = image, Text = "CARBON", Visible = true, ContextMenuStrip = menu };
        icon.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) onOpen();
        };
    }

    /// <summary>The tooltip, e.g. "CARBON · LINKED · IPHONE" (Windows allows 63 characters).</summary>
    public void SetStatus(string status)
    {
        var text = $"CARBON · {status}";
        icon.Text = text.Length > 63 ? text[..63] : text;
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        image.Dispose();
    }

    /// <summary>A 5×7 dot "C" in Tactura white, drawn at 32 px.</summary>
    private static Icon DotMatrixC()
    {
        string[] rows = [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."];
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var dot = new SolidBrush(Color.FromArgb(0xF4, 0xF4, 0xF1));
            const float pitch = 4.4f, size = 3.6f;
            var left = (32 - pitch * 5) / 2;
            var top = (32 - pitch * 7) / 2;
            for (var row = 0; row < rows.Length; row++)
                for (var column = 0; column < rows[row].Length; column++)
                    if (rows[row][column] == '#')
                        g.FillEllipse(dot, left + column * pitch, top + row * pitch, size, size);
        }
        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);
}
