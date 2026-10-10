using System.Collections.ObjectModel;
using System.Windows;
using Carbon.Link;
using Carbon.Output;

namespace Carbon.Companion;

/// <summary>
/// CARBON Companion (SPEC 6.7, 10): a tray app that holds the Bluetooth link to the paired phone,
/// puts each clip on the clipboard (and pastes it when asked and allowed), acks it, and shows a toast.
/// One instance per user.
/// </summary>
public partial class App : Application
{
    private Mutex? singleInstance;
    private string? adapterProblem;

    public CompanionLog Log { get; } = new();
    public CompanionSettings Settings { get; private set; } = null!;
    public PhoneLink Link { get; private set; } = null!;
    public TrayIcon Tray { get; private set; } = null!;
    public ObservableCollection<RecentClip> Recent { get; } = [];
    private PanelWindow panel = null!;
    private ToastWindow toast = null!;

    protected override async void OnStartup(StartupEventArgs e)
    {
        singleInstance = new Mutex(true, @"Local\CARBON.Companion", out var first);
        if (!first)
        {
            Shutdown();
            return;
        }
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            Log.Write($"unhandled: {args.Exception.GetType().Name}: {args.Exception.Message}");
            args.Handled = true;
        };

        Settings = CompanionSettings.Load(Log.Write);
        Log.Write($"CARBON Companion started as '{Settings.EffectiveLaptopName}'");
        LaunchAtLogin.Apply(Settings.LaunchAtLogin, Log.Write);

        Link = new PhoneLink(new Hello(Protocol.Version, Settings.LaptopId, Settings.EffectiveLaptopName), Log.Write)
        {
            DeliverClip = clip => Dispatcher.InvokeAsync(() => DeliverAsync(clip)).Task.Unwrap(),
        };
        Link.StateChanged += state => Dispatcher.InvokeAsync(() => panel.ShowLink(state, Link.PhoneName, adapterProblem));

        Tray = new TrayIcon(onOpen: () => panel.Toggle(), onQuit: Quit);
        toast = new ToastWindow();
        panel = new PanelWindow(this);

        adapterProblem = await PhoneLink.CheckAdapterAsync();
        if (adapterProblem is not null) Log.Write($"Bluetooth: {adapterProblem}");
        panel.ShowLink(Link.State, Settings.PairedPhoneName, adapterProblem);
        await ResumeLinkAsync();
        if (Settings.PairedDeviceId is null) panel.Open();   // first run: show how to pair
    }

    /// <summary>Connects to the paired phone, if any, and keeps reconnecting.</summary>
    public async Task ResumeLinkAsync()
    {
        if (Settings.PairedDeviceId is { } id) await Link.StartAsync(id, Settings.PairedPhoneName);
    }

    public async Task PairedAsync(string deviceId, string? phoneName, string? classicTwinId)
    {
        Settings.PairedDeviceId = deviceId;
        Settings.PairedPhoneName = phoneName;
        Settings.PairedClassicTwinId = classicTwinId;
        Settings.Save();
        Log.Write($"paired with '{phoneName}'");
        await Link.StartAsync(deviceId, phoneName);
        panel.ShowLink(Link.State, phoneName, adapterProblem);
    }

    public async Task ForgetPhoneAsync()
    {
        if (Settings.PairedDeviceId is { } id) await Link.ForgetAsync(id, Settings.PairedClassicTwinId);
        Settings.PairedDeviceId = null;
        Settings.PairedPhoneName = null;
        Settings.PairedClassicTwinId = null;
        Settings.Save();
        panel.ShowLink(LinkState.NoPhone, null, adapterProblem);
    }

    /// <summary>
    /// One clip, on the UI thread (the clipboard needs STA): clipboard, then autopaste when the clip
    /// asks for it and this PC allows it, then the toast (after the paste, so it can't catch the keys).
    /// </summary>
    private async Task<string> DeliverAsync(Clip clip)
    {
        string result;
        if (!await ClipboardWriter.TrySetTextAsync(clip.Text))
        {
            result = AckResult.Error;
        }
        else if (!clip.WantsAutopaste)
        {
            result = AckResult.Copied;
        }
        else if (!Settings.AllowAutopaste)
        {
            result = AckResult.AutopasteDisabled;
        }
        else
        {
            try
            {
                result = await AutoPaster.PasteAsync() == PasteOutcome.Pasted ? AckResult.Pasted : AckResult.PasteBlocked;
            }
            catch (Exception ex)
            {
                Log.Write($"autopaste failed: {ex.Message}");
                result = AckResult.PasteBlocked;
            }
        }

        Log.Write($"clip {clip.Text.Length} chars, {clip.Mode} -> {result}");
        var label = result switch
        {
            AckResult.Pasted => "PASTED",
            AckResult.Copied => "COPIED",
            AckResult.PasteBlocked => "COPIED · ADMIN WINDOW",
            AckResult.AutopasteDisabled => "COPIED · AUTOPASTE OFF",
            _ => "FAILED",
        };
        Recent.Insert(0, new RecentClip(DateTime.Now.ToString("HH:mm"), $"{clip.Text.Length} CH", label));
        while (Recent.Count > 8) Recent.RemoveAt(Recent.Count - 1);
        if (Settings.Toasts && result != AckResult.Error)
            toast.Show($"{label} · {clip.Text.Length} CHARS", fresh: result is AckResult.Pasted or AckResult.Copied);
        return result;
    }

    public async void Quit()
    {
        Log.Write("quitting");
        await Link.DisposeAsync();
        Tray.Dispose();
        singleInstance?.ReleaseMutex();
        Shutdown();
    }
}
