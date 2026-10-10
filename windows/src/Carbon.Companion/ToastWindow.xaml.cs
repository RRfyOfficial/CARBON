using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace Carbon.Companion;

/// <summary>
/// The delivery toast (SPEC 6.7, 10): bottom-right for 2.5 s, topmost, and never activated, so an
/// autopaste can't land in it. It's shown after the paste.
/// </summary>
public partial class ToastWindow : Window
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2.5) };

    public ToastWindow()
    {
        InitializeComponent();
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Hide();
        };
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = GetWindowLongPtr(handle, GWL_EXSTYLE);
            SetWindowLongPtr(handle, GWL_EXSTYLE, style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
        };
    }

    public void Show(string message, bool fresh)
    {
        Message.Text = message;
        Dot.Visibility = fresh ? Visibility.Visible : Visibility.Collapsed;
        timer.Stop();
        Show();
        UpdateLayout();
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 16;
        Top = area.Bottom - ActualHeight - 16;
        timer.Start();
    }

    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TOPMOST = 0x00000008, WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern long GetWindowLongPtr(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern long SetWindowLongPtr(IntPtr window, int index, long value);
}
