using System.Reflection;
using System.Windows;
using System.Windows.Media;
using Carbon.Link;

namespace Carbon.Companion;

/// <summary>One delivery in 02 / RECENT, e.g. "12:41   214 CH   PASTED". Lengths only, never text.</summary>
public sealed record RecentClip(string Time, string Chars, string Result);

/// <summary>
/// The tray panel: link badge, 01 / PAIRING while unpaired or pairing, 02 / RECENT,
/// 03 / SETTINGS. Opens above the tray and hides when it loses focus, except during a pairing.
/// </summary>
public partial class PanelWindow : Window
{
    private readonly App app;
    private CancellationTokenSource? pairing;
    private DateTime hiddenAt;

    public PanelWindow(App app)
    {
        this.app = app;
        InitializeComponent();
        VersionText.Text = "v" + (Assembly.GetExecutingAssembly().GetName().Version?.ToString(2) ?? "0.1");
        RecentList.ItemsSource = app.Recent;
        app.Recent.CollectionChanged += (_, _) => RecentEmpty.Visibility = app.Recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        AutopasteToggle.IsChecked = app.Settings.AllowAutopaste;
        LoginToggle.IsChecked = app.Settings.LaunchAtLogin;
        ToastToggle.IsChecked = app.Settings.Toasts;
        if (LaunchAtLogin.IsDevelopmentBuild) LoginToggle.Content = "LAUNCH AT LOGIN (NOT IN DEV BUILDS)";
        Deactivated += (_, _) =>
        {
            if (pairing is not null) return;
            hiddenAt = DateTime.UtcNow;
            Hide();
        };
        SizeChanged += (_, _) => PlaceAboveTray();
    }

    /// <summary>Tray click: show or hide. A click that just hid the panel (by taking focus) doesn't reopen it.</summary>
    public void Toggle()
    {
        if (IsVisible) Hide();
        else if (DateTime.UtcNow - hiddenAt > TimeSpan.FromMilliseconds(300)) Open();
    }

    public void Open()
    {
        Show();
        PlaceAboveTray();
        Activate();
    }

    /// <summary>The badge and which sections show, from the link state.</summary>
    public void ShowLink(LinkState state, string? phoneName, string? adapterProblem)
    {
        var phone = (phoneName ?? app.Settings.PairedPhoneName ?? "PHONE").ToUpperInvariant();
        var (text, color) = adapterProblem is not null
            ? (adapterProblem, Brush("Accent"))
            : state switch
            {
                LinkState.NoPhone => ("NO PHONE PAIRED", Brush("TextDim")),
                LinkState.Waiting => ($"WAITING · {phone}", Brush("TextDim")),
                LinkState.Connected => ($"CONNECTING · {phone}", Brush("TextMuted")),
                LinkState.Linked => ($"LINKED · {phone}", Brush("Text")),
                LinkState.VersionMismatch => ("VERSION MISMATCH · UPDATE", Brush("Accent")),
                _ => (state.ToString().ToUpperInvariant(), Brush("TextDim")),
            };
        LinkText.Text = text;
        LinkDot.Fill = color;
        app.Tray.SetStatus(text);

        var paired = app.Settings.PairedDeviceId is not null;
        if (pairing is null) PairingSection.Visibility = paired ? Visibility.Collapsed : Visibility.Visible;
        ForgetButton.Visibility = paired ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Pairing (PROTOCOL.md Section 3)

    private async void Pair_Click(object sender, RoutedEventArgs e)
    {
        pairing = new CancellationTokenSource();
        ForgetHint.Visibility = Visibility.Collapsed;
        ShowPairStep("Searching for a phone with CARBON open…", cancel: true);
        var result = await app.Link.PairAsync(step => Dispatcher.Invoke(() => OnPairProgress(step)), pairing.Token);
        pairing = null;
        if (result.Ok)
        {
            await app.PairedAsync(result.DeviceId!, result.PhoneName, result.ClassicTwinId);
            ShowPairStep($"Paired with {result.PhoneName}.", cancel: false);
            PairButton.Visibility = Visibility.Collapsed;
            PairingSection.Visibility = Visibility.Collapsed;
        }
        else
        {
            ShowPairStep(result.Problem ?? "Cancelled.", cancel: false, problem: result.Problem is not null);
            await app.ResumeLinkAsync();
        }
    }

    /// <summary>
    /// The phone's own "Pair" prompt is the confirmation. iOS 27 shows no code there, so the panel
    /// shows none either.
    /// </summary>
    private void OnPairProgress(string step)
    {
        switch (step)
        {
            case "CONNECTING":
                ShowPairStep("Found it. Connecting…", cancel: false);
                break;
            case "TAP PAIR":
                ShowPairStep("Tap Pair on your phone.", cancel: false);
                Open();
                break;
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => pairing?.Cancel();

    private void ShowPairStep(string text, bool cancel, bool problem = false)
    {
        PairingSection.Visibility = Visibility.Visible;
        PairStatus.Text = text;
        PairStatus.Foreground = problem ? Brush("Accent") : Brush("Text");
        PairButton.Visibility = cancel || pairing is not null ? Visibility.Collapsed : Visibility.Visible;
        CancelButton.Visibility = cancel ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Settings

    private void Setting_Click(object sender, RoutedEventArgs e)
    {
        app.Settings.AllowAutopaste = AutopasteToggle.IsChecked == true;
        app.Settings.Toasts = ToastToggle.IsChecked == true;
        if (app.Settings.LaunchAtLogin != (LoginToggle.IsChecked == true))
        {
            app.Settings.LaunchAtLogin = LoginToggle.IsChecked == true;
            LaunchAtLogin.Apply(app.Settings.LaunchAtLogin, app.Log.Write);
        }
        app.Settings.Save();
    }

    private async void Forget_Click(object sender, RoutedEventArgs e)
    {
        await app.ForgetPhoneAsync();
        ForgetHint.Text = $"Forgotten on this PC. On the phone, also remove {app.Settings.EffectiveLaptopName}: Settings → Bluetooth → (i) → Forget This Device.";
        ForgetHint.Visibility = Visibility.Visible;
        ShowPairStep("Open CARBON on your phone, then pair.", cancel: false);
    }

    private void Quit_Click(object sender, RoutedEventArgs e) => app.Quit();

    private void PlaceAboveTray()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
    }

    private Brush Brush(string key) => (Brush)FindResource(key);
}
