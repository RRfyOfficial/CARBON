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

public sealed record PairResult(string? DeviceId, string? PhoneName, string? Problem)
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
    private GattCharacteristic? p2l;
    private GattCharacteristic? l2p;
    private ushort nextMsgId;

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
        session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
        session.MaintainConnection = true;
        log($"holding the link to '{device.Name}' (now {device.ConnectionStatus})");
        SetState(LinkState.Waiting);
        if (device.ConnectionStatus == BluetoothConnectionStatus.Connected) await SetUpAsync();
    }

    public async Task StopAsync()
    {
        running?.Cancel();
        running = null;
        inbound?.Writer.TryComplete();
        inbound = null;
        if (p2l is not null) p2l.ValueChanged -= OnValueChanged;
        p2l = l2p = null;
        if (device is not null) device.ConnectionStatusChanged -= OnConnectionStatusChanged;
        session?.Dispose();
        device?.Dispose();
        session = null;
        device = null;
        await Task.CompletedTask;
    }

    /// <summary>
    /// PROTOCOL.md Section 3: find a phone with CARBON open, read INFO, then pair with numeric
    /// comparison. <paramref name="confirmCode"/> shows the 6-digit code and returns true on CONFIRM.
    /// </summary>
    public async Task<PairResult> PairAsync(Func<string, Task<bool>> confirmCode, Action<string> progress, CancellationToken cancel)
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
        custom.PairingRequested += async (_, request) =>
        {
            var deferral = request.GetDeferral();
            try
            {
                log($"pairing request ({request.PairingKind})");
                if (await confirmCode(request.Pin ?? "")) request.Accept();
            }
            finally
            {
                deferral.Complete();
            }
        };
        progress("CODE");
        var result = await custom.PairAsync(DevicePairingKinds.ConfirmPinMatch | DevicePairingKinds.DisplayPin,
                                            DevicePairingProtectionLevel.EncryptionAndAuthentication);
        log($"pairing: {result.Status}");
        return result.Status switch
        {
            DevicePairingResultStatus.Paired or DevicePairingResultStatus.AlreadyPaired => new(phone.DeviceId, info.Value.Name, null),
            DevicePairingResultStatus.RejectedByHandler => new(null, null, "REJECTED"),
            _ => new(null, null, $"PAIRING FAILED ({result.Status}) · ON THE PHONE, FORGET {Environment.MachineName.ToUpperInvariant()} IN BLUETOOTH SETTINGS IF IT'S LISTED, THEN TRY AGAIN"),
        };
    }

    /// <summary>Removes the Windows bond with the phone.</summary>
    public async Task ForgetAsync(string deviceId)
    {
        await StopAsync();
        using var phone = await BluetoothLEDevice.FromIdAsync(deviceId);
        if (phone is not null)
        {
            var result = await phone.DeviceInformation.Pairing.UnpairAsync();
            log($"forgot the phone: {result.Status}");
        }
        PhoneName = null;
        SetState(LinkState.NoPhone);
    }

    public async ValueTask DisposeAsync() => await StopAsync();

    // MARK: - Connection

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

    /// <summary>On every connect: characteristics (uncached), version, encryption, subscription, hello.</summary>
    private async Task SetUpAsync()
    {
        await setupGate.WaitAsync();
        try
        {
            if (device is not { } phone) return;
            var characteristics = await CharacteristicsAsync(phone);
            if (characteristics is null) return;
            if (!characteristics.TryGetValue(Protocol.P2L, out var notify) || !characteristics.TryGetValue(Protocol.L2P, out var write))
            {
                log("the phone's CARBON service is missing P2L or L2P");
                SetState(LinkState.VersionMismatch);
                return;
            }
            if (await ReadInfoAsync(characteristics) is { } info && info.Proto != Protocol.Version)
            {
                log($"phone speaks protocol {info.Proto}, this companion {Protocol.Version}");
                SetState(LinkState.VersionMismatch);
                return;
            }

            if (p2l is not null) p2l.ValueChanged -= OnValueChanged;
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
                return;
            }
            log($"subscribed (max PDU {session?.MaxPduSize})");
            SetState(LinkState.Connected);
            await SendAsync(Messages.Encode(hello));
        }
        catch (Exception ex)
        {
            log($"set-up failed: {ex.Message}");
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

    private async Task<Dictionary<Guid, GattCharacteristic>?> CharacteristicsAsync(BluetoothLEDevice phone)
    {
        var services = await phone.GetGattServicesForUuidAsync(Protocol.Service, BluetoothCacheMode.Uncached);
        if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
        {
            log($"CARBON service: {services.Status}, {services.Services.Count} found");
            return null;
        }
        var result = await services.Services[0].GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
        if (result.Status != GattCommunicationStatus.Success)
        {
            log($"characteristics: {result.Status}");
            return null;
        }
        return result.Characteristics.ToDictionary(c => c.Uuid);
    }

    private async Task<(int Proto, string Name)?> ReadInfoAsync(BluetoothLEDevice phone) =>
        await CharacteristicsAsync(phone) is { } characteristics ? await ReadInfoAsync(characteristics) : null;

    private async Task<(int Proto, string Name)?> ReadInfoAsync(Dictionary<Guid, GattCharacteristic> characteristics)
    {
        if (!characteristics.TryGetValue(Protocol.Info, out var info)) return null;
        var read = await info.ReadValueAsync(BluetoothCacheMode.Uncached);
        if (read.Status != GattCommunicationStatus.Success)
        {
            log($"INFO read: {read.Status}");
            return null;
        }
        try
        {
            using var json = JsonDocument.Parse(Bytes(read.Value));
            var root = json.RootElement;
            var proto = root.TryGetProperty("proto", out var p) && p.TryGetInt32(out var n) ? n : 0;
            var name = root.TryGetProperty("name", out var nm) ? nm.GetString() ?? "IPHONE" : "IPHONE";
            return (proto, name);
        }
        catch (JsonException)
        {
            log("INFO isn't JSON");
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
