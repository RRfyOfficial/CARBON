using System.Text.Json;
using System.Threading.Channels;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Storage.Streams;

namespace Carbon.Link;

public enum LinkState
{
    /// <summary>No phone paired yet.</summary>
    NoPhone,
    /// <summary>Paired, waiting for the phone (out of range, its Bluetooth off, CARBON not running).</summary>
    Waiting,
    /// <summary>Connected and subscribed; waiting for the phone's hello.</summary>
    Connected,
    /// <summary>Hellos exchanged: clips can arrive.</summary>
    Linked,
    /// <summary>The phone speaks another protocol version.</summary>
    VersionMismatch,
}

/// <summary>
/// A finished pairing. <see cref="ClassicTwinId"/> is the Bluetooth Classic pairing Windows and iOS
/// derive alongside the LE bond; it has to go with it on FORGET, or Windows reuses its stale keys.
/// </summary>
public sealed record PairResult(string? DeviceId, string? PhoneName, string? Problem, string? ClassicTwinId = null)
{
    public bool Ok => DeviceId is not null;
}

/// <summary>
/// The laptop side of the link (PROTOCOL.md): a BLE central that pairs with the phone through the
/// Windows Bluetooth bond, then holds the connection with MaintainConnection, so Windows reconnects
/// by itself whenever the phone is in range, also while CARBON is in the background (M2 link spike).
/// On every connect it fetches the characteristics again, asks for encryption, subscribes to P2L and
/// sends hello. Clips arrive one at a time on a background thread.
/// </summary>
public sealed class PhoneLink(Hello hello, Action<string> log) : IAsyncDisposable
{
    private readonly ClipDedupe dedupe = new();
    private readonly Reassembler reassembler = new();
    private readonly SemaphoreSlim setupGate = new(1, 1);
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private Channel<byte[]>? inbound;
    private CancellationTokenSource? running;
    private BluetoothLEDevice? device;
    private GattSession? session;
    // Held while linked and disposed before the next fetch: an undisposed service from an earlier
    // fetch (the pairing's INFO read) made the next one fail with AccessDenied.
    private GattDeviceService? service;
    private GattCharacteristic? p2l;
    private GattCharacteristic? l2p;
    private GattCharacteristic? info;
    /// <summary>INFO's per-launch id at the last set-up: a different one means CARBON restarted.</summary>
    private string? phoneBoot;
    private ushort nextMsgId;
    private static readonly TimeSpan WatchInterval = TimeSpan.FromSeconds(30);

    public LinkState State { get; private set; } = LinkState.NoPhone;
    public string? PhoneName { get; private set; }
    public event Action<LinkState>? StateChanged;

    /// <summary>Puts one clip on the clipboard (and pastes it) and returns the ack result.</summary>
    public Func<Clip, Task<string>>? DeliverClip { get; set; }

    /// <summary>Null when this PC can't be a Bluetooth LE central, otherwise a reason to show.</summary>
    public static async Task<string?> CheckAdapterAsync()
    {
        var adapter = await BluetoothAdapter.GetDefaultAsync();
        if (adapter is null) return "NO BLUETOOTH ADAPTER";
        if (!adapter.IsLowEnergySupported || !adapter.IsCentralRoleSupported) return "BLUETOOTH LE NOT SUPPORTED";
        return null;
    }

    /// <summary>Connects to the paired phone and keeps reconnecting until stopped.</summary>
    public async Task StartAsync(string deviceId, string? phoneName)
    {
        await StopAsync();
        PhoneName = phoneName;
        running = new CancellationTokenSource();
        inbound = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
        _ = Task.Run(() => HandleMessagesAsync(inbound.Reader, running.Token));

        device = await BluetoothLEDevice.FromIdAsync(deviceId);
        if (device is null)
        {
            log("paired phone not found in Windows' Bluetooth devices");
            SetState(LinkState.NoPhone);
            return;
        }
        device.ConnectionStatusChanged += OnConnectionStatusChanged;
        device.GattServicesChanged += OnServicesChanged;
        session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
        session.MaintainConnection = true;
        log($"holding the link to '{device.Name}' (now {device.ConnectionStatus})");
        SetState(LinkState.Waiting);
        _ = Task.Run(() => WatchAsync(running.Token));
        if (device.ConnectionStatus == BluetoothConnectionStatus.Connected) await SetUpAsync();
    }

    public async Task StopAsync()
    {
        running?.Cancel();
        running = null;
        inbound?.Writer.TryComplete();
        inbound = null;
        if (p2l is not null) p2l.ValueChanged -= OnValueChanged;
        p2l = l2p = info = null;
        service?.Dispose();
        service = null;
        if (device is not null)
        {
            device.ConnectionStatusChanged -= OnConnectionStatusChanged;
            device.GattServicesChanged -= OnServicesChanged;
        }
        session?.Dispose();
        device?.Dispose();
        session = null;
        device = null;
        await Task.CompletedTask;
    }

    /// <summary>
    /// PROTOCOL.md Section 3: find a phone with CARBON open, read INFO, then pair (LE Secure
    /// Connections). The laptop accepts on its side; the wearer's Pair tap on the phone is the
    /// confirmation. iOS 27 shows no code to compare, so the companion doesn't show one either.
    /// Progress steps: SEARCHING, CONNECTING, TAP PAIR.
    /// </summary>
    public async Task<PairResult> PairAsync(Action<string> progress, CancellationToken cancel)
    {
        await StopAsync();
        progress("SEARCHING");
        var address = await FindPhoneAsync(TimeSpan.FromSeconds(30), cancel);
        if (address is null) return new(null, null, cancel.IsCancellationRequested ? null : "NO PHONE FOUND · IS CARBON OPEN ON IT?");

        progress("CONNECTING");
        var found = await BluetoothLEDevice.FromBluetoothAddressAsync(address.Value);
        if (found.DeviceInformation.Pairing.IsPaired)
        {
            // A bond left over from before would make Windows reuse dead keys (CLAUDE.md, section 8).
            log("removing an old Windows pairing with this phone first");
            await found.DeviceInformation.Pairing.UnpairAsync();
            found.Dispose();
            found = await BluetoothLEDevice.FromBluetoothAddressAsync(address.Value);
        }
        using var phone = found;

        var info = await ReadInfoAsync(phone);
        if (info is null) return new(null, null, "COULDN'T READ THE PHONE · TRY AGAIN");
        if (info.Value.Proto != Protocol.Version) return new(null, null, "VERSION MISMATCH · UPDATE CARBON OR THE COMPANION");

        var custom = phone.DeviceInformation.Pairing.Custom;
        custom.PairingRequested += (_, request) =>
        {
            log($"pairing request ({request.PairingKind})");
            request.Accept();
            progress("TAP PAIR");
        };
        var classicBefore = await PairedClassicIdsAsync();
        var result = await custom.PairAsync(DevicePairingKinds.ConfirmPinMatch | DevicePairingKinds.DisplayPin,
                                            DevicePairingProtectionLevel.EncryptionAndAuthentication);
        log($"pairing: {result.Status}");
        string? twin = null;
        if (result.Status is DevicePairingResultStatus.Paired or DevicePairingResultStatus.AlreadyPaired)
        {
            await Task.Delay(TimeSpan.FromSeconds(1));
            twin = (await PairedClassicIdsAsync()).Except(classicBefore).FirstOrDefault();
            log(twin is null ? "no Classic twin appeared" : "noted the Classic twin of the bond");
        }
        return result.Status switch
        {
            DevicePairingResultStatus.Paired or DevicePairingResultStatus.AlreadyPaired => new(phone.DeviceId, info.Value.Name, null, twin),
            _ => new(null, null, $"PAIRING FAILED ({result.Status}) · IF YOU TAPPED PAIR, FORGET {Environment.MachineName.ToUpperInvariant()} IN THE PHONE'S BLUETOOTH SETTINGS, THEN TRY AGAIN"),
        };
    }

    /// <summary>Removes the Windows bond with the phone, and its Classic twin when known.</summary>
    public async Task ForgetAsync(string deviceId, string? classicTwinId)
    {
        await StopAsync();
        using var phone = await BluetoothLEDevice.FromIdAsync(deviceId);
        if (phone is not null)
        {
            var result = await phone.DeviceInformation.Pairing.UnpairAsync();
            log($"forgot the phone: {result.Status}");
        }
        if (classicTwinId is not null && await BluetoothDevice.FromIdAsync(classicTwinId) is { } twin)
        {
            using (twin)
            {
                var result = await twin.DeviceInformation.Pairing.UnpairAsync();
                log($"forgot its Classic twin: {result.Status}");
            }
        }
        PhoneName = null;
        SetState(LinkState.NoPhone);
    }

    private static async Task<HashSet<string>> PairedClassicIdsAsync()
    {
        var paired = await DeviceInformation.FindAllAsync(BluetoothDevice.GetDeviceSelectorFromPairingState(true));
        return paired.Select(d => d.Id).ToHashSet();
    }

    public async ValueTask DisposeAsync() => await StopAsync();

    // MARK: - Connection

    /// <summary>CARBON restarted (or its service changed) without the Bluetooth link dropping.</summary>
    private void OnServicesChanged(BluetoothLEDevice sender, object args)
    {
        log("the phone's services changed; setting up again");
        _ = SetUpAsync();
    }

    /// <summary>
    /// Every 30 s while connected: not linked → try the set-up again; linked → read INFO, and a
    /// failed read or a new per-launch id means CARBON restarted (PROTOCOL.md Section 3).
    /// </summary>
    private async Task WatchAsync(CancellationToken cancel)
    {
        using var timer = new PeriodicTimer(WatchInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(cancel))
            {
                if (device?.ConnectionStatus != BluetoothConnectionStatus.Connected) continue;
                if (State == LinkState.Linked)
                {
                    if (await SameCarbonAsync()) continue;
                    log("CARBON restarted on the phone; setting up again");
                    SetState(LinkState.Waiting);
                }
                await SetUpAsync();
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task<bool> SameCarbonAsync()
    {
        if (info is not { } characteristic) return false;
        try
        {
            var read = await characteristic.ReadValueAsync(BluetoothCacheMode.Uncached);
            return read.Status == GattCommunicationStatus.Success && ParseInfo(Bytes(read.Value))?.Boot == phoneBoot;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        log($"connection: {sender.ConnectionStatus}");
        if (sender.ConnectionStatus == BluetoothConnectionStatus.Connected)
        {
            _ = SetUpAsync();
        }
        else if (State != LinkState.VersionMismatch)
        {
            SetState(LinkState.Waiting);
        }
    }

    /// <summary>
    /// On every connect: characteristics (uncached), version, encryption, subscription, hello.
    /// A failed attempt while still connected is retried, up to 5 times 2 s apart.
    /// </summary>
    private async Task SetUpAsync(int attempt = 1)
    {
        if (!await TrySetUpAsync() && attempt < 5 && device?.ConnectionStatus == BluetoothConnectionStatus.Connected)
        {
            log($"set-up attempt {attempt} failed; retrying");
            await Task.Delay(TimeSpan.FromSeconds(2));
            await SetUpAsync(attempt + 1);
        }
    }

    private async Task<bool> TrySetUpAsync()
    {
        await setupGate.WaitAsync();
        try
        {
            if (device is not { } phone) return true;
            if (p2l is not null) p2l.ValueChanged -= OnValueChanged;
            p2l = l2p = info = null;
            service?.Dispose();
            service = null;

            if (await CharacteristicsAsync(phone) is not var (opened, characteristics)) return false;
            service = opened;
            if (!characteristics.TryGetValue(Protocol.P2L, out var notify) || !characteristics.TryGetValue(Protocol.L2P, out var write))
            {
                log("the phone's CARBON service is missing P2L or L2P");
                SetState(LinkState.VersionMismatch);
                return true;
            }
            var phoneInfo = await ReadInfoAsync(characteristics);
            if (phoneInfo is { } mismatch && mismatch.Proto != Protocol.Version)
            {
                log($"phone speaks protocol {mismatch.Proto}, this companion {Protocol.Version}");
                SetState(LinkState.VersionMismatch);
                return true;
            }
            info = characteristics.GetValueOrDefault(Protocol.Info);
            phoneBoot = phoneInfo?.Boot;

            lock (reassembler) reassembler.Reset();
            // Windows only encrypts the link when a request asks for it (CLAUDE.md, section 8).
            notify.ProtectionLevel = GattProtectionLevel.EncryptionRequired;
            write.ProtectionLevel = GattProtectionLevel.EncryptionRequired;
            notify.ValueChanged += OnValueChanged;
            p2l = notify;
            l2p = write;
            var status = await notify.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (status != GattCommunicationStatus.Success)
            {
                log($"subscribing failed: {status}");
                return false;
            }
            log($"subscribed (max PDU {session?.MaxPduSize})");
            SetState(LinkState.Connected);
            return await SendAsync(Messages.Encode(hello));
        }
        catch (Exception ex)
        {
            log($"set-up failed: {ex.Message}");
            return false;
        }
        finally
        {
            setupGate.Release();
        }
    }

    private void OnValueChanged(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        var frame = Bytes(args.CharacteristicValue);
        byte[]? message;
        lock (reassembler) message = reassembler.Add(frame);
        if (message is not null) inbound?.Writer.TryWrite(message);
    }

    private async Task HandleMessagesAsync(ChannelReader<byte[]> reader, CancellationToken cancel)
    {
        try
        {
            await foreach (var bytes in reader.ReadAllAsync(cancel))
            {
                try
                {
                    await HandleAsync(bytes);
                }
                catch (Exception ex)
                {
                    log($"handling a message failed: {ex.Message}");
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task HandleAsync(byte[] bytes)
    {
        var message = Messages.Decode(bytes);
        switch (message)
        {
            case Hello phoneHello when phoneHello.Proto != Protocol.Version:
                log($"phone hello with protocol {phoneHello.Proto}");
                SetState(LinkState.VersionMismatch);
                break;
            case Hello phoneHello:
                PhoneName = phoneHello.Name;
                log($"linked with '{phoneHello.Name}'");
                SetState(LinkState.Linked);
                break;
            case Clip clip:
                string result;
                if (dedupe.TryGet(clip.Id, out var earlier))
                {
                    result = earlier;
                    log($"repeated clip, acked again ({result}), not pasted");
                }
                else
                {
                    result = DeliverClip is null ? AckResult.Error : await DeliverClip(clip);
                    dedupe.Remember(clip.Id, result);
                }
                await SendAsync(Messages.Encode(new Ack(clip.Id, result)));
                break;
            default:
                log($"ignored a {bytes.Length}-byte message");
                break;
        }
    }

    private async Task<bool> SendAsync(byte[] message)
    {
        await writeGate.WaitAsync();
        try
        {
            if (l2p is not { } target)
            {
                log("can't send: not connected");
                return false;
            }
            var chunk = Framing.ChunkSize((session?.MaxPduSize ?? 23) - 3);
            foreach (var frame in Framing.Split(message, nextMsgId++, chunk))
            {
                var result = await target.WriteValueWithResultAsync(Buffer(frame), GattWriteOption.WriteWithResponse);
                if (result.Status != GattCommunicationStatus.Success)
                {
                    log($"write failed: {result.Status} (protocol error {result.ProtocolError})");
                    return false;
                }
            }
            return true;
        }
        catch (Exception ex)
        {
            log($"write failed: {ex.Message}");
            return false;
        }
        finally
        {
            writeGate.Release();
        }
    }

    // MARK: - Helpers

    /// <summary>The phone's address from its CARBON advertisement, only visible while CARBON is on screen.</summary>
    private async Task<ulong?> FindPhoneAsync(TimeSpan timeout, CancellationToken cancel)
    {
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(Protocol.Service);
        var found = new TaskCompletionSource<ulong>(TaskCreationOptions.RunContinuationsAsynchronously);
        watcher.Received += (_, e) => found.TrySetResult(e.BluetoothAddress);
        watcher.Start();
        try
        {
            await Task.WhenAny(found.Task, Task.Delay(timeout, cancel)).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            watcher.Stop();
        }
        return found.Task.IsCompletedSuccessfully ? found.Task.Result : null;
    }

    /// <summary>The CARBON service, opened shared, and its characteristics. The caller disposes the service.</summary>
    private async Task<(GattDeviceService Service, Dictionary<Guid, GattCharacteristic> Characteristics)?> CharacteristicsAsync(BluetoothLEDevice phone)
    {
        var services = await phone.GetGattServicesForUuidAsync(Protocol.Service, BluetoothCacheMode.Uncached);
        if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
        {
            log($"CARBON service: {services.Status}, {services.Services.Count} found");
            return null;
        }
        var service = services.Services[0];
        foreach (var extra in services.Services.Skip(1)) extra.Dispose();
        var open = await service.OpenAsync(GattSharingMode.SharedReadAndWrite);
        if (open is not (GattOpenStatus.Success or GattOpenStatus.AlreadyOpened))
            log($"opening the CARBON service: {open}");
        var result = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
        if (result.Status != GattCommunicationStatus.Success)
        {
            log($"characteristics: {result.Status}");
            service.Dispose();
            return null;
        }
        return (service, result.Characteristics.ToDictionary(c => c.Uuid));
    }

    /// <summary>INFO for pairing; the service is closed again right after.</summary>
    private async Task<(int Proto, string Name, string? Boot)?> ReadInfoAsync(BluetoothLEDevice phone)
    {
        if (await CharacteristicsAsync(phone) is not var (service, characteristics)) return null;
        using (service) return await ReadInfoAsync(characteristics);
    }

    private async Task<(int Proto, string Name, string? Boot)?> ReadInfoAsync(Dictionary<Guid, GattCharacteristic> characteristics)
    {
        if (!characteristics.TryGetValue(Protocol.Info, out var characteristic)) return null;
        var read = await characteristic.ReadValueAsync(BluetoothCacheMode.Uncached);
        if (read.Status != GattCommunicationStatus.Success)
        {
            log($"INFO read: {read.Status}");
            return null;
        }
        var parsed = ParseInfo(Bytes(read.Value));
        if (parsed is null) log("INFO isn't JSON");
        return parsed;
    }

    /// <summary>INFO's JSON; `boot` is absent on phones from before it was added.</summary>
    private static (int Proto, string Name, string? Boot)? ParseInfo(byte[] json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var proto = root.TryGetProperty("proto", out var p) && p.TryGetInt32(out var n) ? n : 0;
            var name = root.TryGetProperty("name", out var nm) ? nm.GetString() ?? "IPHONE" : "IPHONE";
            var boot = root.TryGetProperty("boot", out var b) ? b.GetString() : null;
            return (proto, name, boot);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private void SetState(LinkState state)
    {
        if (State == state) return;
        State = state;
        StateChanged?.Invoke(state);
    }

    private static byte[] Bytes(IBuffer buffer)
    {
        var bytes = new byte[buffer.Length];
        DataReader.FromBuffer(buffer).ReadBytes(bytes);
        return bytes;
    }

    private static IBuffer Buffer(byte[] bytes)
    {
        var writer = new DataWriter();
        writer.WriteBytes(bytes);
        return writer.DetachBuffer();
    }
}
