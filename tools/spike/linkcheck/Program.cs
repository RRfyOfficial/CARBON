// M2 spike: the laptop as the BLE central and the phone as the peripheral (roles swapped),
// because this laptop can't run a GATT server (M0 U8, retested in M2). Works with the LINK TEST
// section in CARBON's Diagnostics. The question: once bonded, does Windows reconnect by itself
// while CARBON is in the background and the phone is locked?
// Usage:
//   linkcheck scan             look for the phone's CARBON advertisement for 10 s
//   linkcheck pair [how]       find it, read INFO, pair at the OS level, read SECURE, remember it.
//                              how: custom (ConfirmOnly, encryption) | auth (code match, MITM
//                              protection) | demand (no explicit pairing: the encrypted read triggers it)
//   linkcheck listen [min]     hold the bonded link: subscribe, ping every 5 s, report drops (default 30 min)
//   linkcheck radio off|on     switch this laptop's Bluetooth radio, to break the link on purpose
//   linkcheck unpair [id]      forget the phone (or the device with this Windows device id)
//   linkcheck unpairclassic <hex address>   forget a Bluetooth Classic pairing (an old Phone Link
//                              pairing with the same iPhone made Windows reuse stale keys)
using System.Text;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Devices.Radios;
using Windows.Storage.Streams;

var serviceId = Guid.Parse("5D7FCEF4-D1AA-46A6-B187-DF5AF19C5BC5");
var infoId = Guid.Parse("C34B4E97-BD2A-4254-A253-B8557272FEBE");
var secureId = Guid.Parse("B8B1C9A1-23D4-4994-A6B0-25E02DD11C99");
var p2lId = Guid.Parse("FA6817D4-2B2E-4AD3-ABB0-8981F0A8C674");
var l2pId = Guid.Parse("4414751E-1E20-4530-AA11-46485950207B");

var stateDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CARBON-spike");
Directory.CreateDirectory(stateDir);
var deviceFile = Path.Combine(stateDir, "device.txt");

void Say(string text) => Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff}  {text}");

switch (args.FirstOrDefault() ?? "scan")
{
    case "scan":
        return await FindPhone(TimeSpan.FromSeconds(10), printAll: true) is null ? 4 : 0;
    case "pair":
        return await Pair(args.ElementAtOrDefault(1) ?? "custom");
    case "listen":
        return await Listen(args.Length > 1 ? double.Parse(args[1]) : 30);
    case "radio":
        return await SetRadio(args.ElementAtOrDefault(1) == "on");
    case "unpair":
        return await Unpair(args.ElementAtOrDefault(1));
    case "unpairclassic":
        return await UnpairClassic(args[1]);
    default:
        Console.WriteLine("usage: linkcheck scan | pair | listen [minutes] | radio off|on | unpair");
        return 2;
}

// The phone's address from its CARBON advertisement (only visible while CARBON is on screen).
async Task<ulong?> FindPhone(TimeSpan timeout, bool printAll)
{
    var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
    watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(serviceId);
    var found = new TaskCompletionSource<ulong>();
    watcher.Received += (_, e) =>
    {
        if (printAll) Say($"seen {e.BluetoothAddress:X12} | {e.AdvertisementType} | RSSI {e.RawSignalStrengthInDBm} | name '{e.Advertisement.LocalName}'");
        found.TrySetResult(e.BluetoothAddress);
    };
    watcher.Stopped += (_, e) => { if (e.Error != BluetoothError.Success) Say($"watcher stopped: {e.Error}"); };
    watcher.Start();
    if (printAll) await Task.Delay(timeout);
    else await Task.WhenAny(found.Task, Task.Delay(timeout));
    watcher.Stop();
    if (!found.Task.IsCompleted) Say("phone not found: is LINK TEST on, and CARBON open on screen?");
    return found.Task.IsCompleted ? found.Task.Result : null;
}

async Task<int> Pair(string how)
{
    var address = await FindPhone(TimeSpan.FromSeconds(20), printAll: false);
    if (address is null) return 4;
    using var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address.Value);
    Say($"device '{device.Name}' | {device.DeviceId} | paired {device.DeviceInformation.Pairing.IsPaired}");
    var chars = await Characteristics(device);
    if (chars is null) return 5;
    Say($"INFO: {await Read(chars[infoId])}");

    if (!device.DeviceInformation.Pairing.IsPaired && how != "demand")
    {
        var custom = device.DeviceInformation.Pairing.Custom;
        custom.PairingRequested += (_, e) =>
        {
            Say($"pairing request | {e.PairingKind} | code {e.Pin} -> the phone should show the same code; tap Pair there");
            e.Accept();
        };
        var result = how == "auth"
            ? await custom.PairAsync(DevicePairingKinds.ConfirmPinMatch | DevicePairingKinds.DisplayPin | DevicePairingKinds.ConfirmOnly,
                                     DevicePairingProtectionLevel.EncryptionAndAuthentication)
            : await custom.PairAsync(DevicePairingKinds.ConfirmOnly | DevicePairingKinds.ConfirmPinMatch | DevicePairingKinds.DisplayPin,
                                     DevicePairingProtectionLevel.Encryption);
        Say($"pairing ({how}): {result.Status} | protection {result.ProtectionLevelUsed}");
        if (result.Status is not (DevicePairingResultStatus.Paired or DevicePairingResultStatus.AlreadyPaired)) return 6;
    }
    else if (how == "demand")
    {
        Say("no explicit pairing: the encrypted read below should make the phone ask; tap Pair there");
    }

    // Windows only encrypts the link when a request asks for it; Plain reads get "insufficient authentication".
    chars[secureId].ProtectionLevel = GattProtectionLevel.EncryptionRequired;
    Say($"SECURE (needs the encrypted link): {await Read(chars[secureId])}");
    Say($"now: paired {device.DeviceInformation.Pairing.IsPaired} | protection {device.DeviceInformation.Pairing.ProtectionLevel}");
    File.WriteAllText(deviceFile, device.DeviceId);
    Say($"remembered {device.DeviceId}");
    foreach (var paired in await DeviceInformation.FindAllAsync(BluetoothLEDevice.GetDeviceSelectorFromPairingState(true)))
        Say($"paired LE device: '{paired.Name}' | {paired.Id}");
    return 0;
}

// Holds the link like the companion would: Windows keeps reconnecting (MaintainConnection), and on
// every reconnect the characteristics are fetched and the subscription renewed.
async Task<int> Listen(double minutes)
{
    if (!File.Exists(deviceFile)) { Say("run `linkcheck pair` first"); return 2; }
    var id = File.ReadAllText(deviceFile).Trim();
    using var device = await BluetoothLEDevice.FromIdAsync(id);
    if (device is null) { Say($"device {id} not found"); return 4; }
    Say($"device '{device.Name}' | paired {device.DeviceInformation.Pairing.IsPaired} | {device.ConnectionStatus}");
    using var session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
    session.MaintainConnection = true;
    session.SessionStatusChanged += (_, e) => Say($"session: {e.Status} ({e.Error})");

    GattCharacteristic? p2l = null, l2p = null;
    var gate = new SemaphoreSlim(1, 1);
    void OnValue(GattCharacteristic _, GattValueChangedEventArgs e) => Say($"<- {Text(e.CharacteristicValue)}");

    async Task Subscribe()
    {
        await gate.WaitAsync();
        try
        {
            var chars = await Characteristics(device);
            if (chars is null) return;
            if (p2l is not null) p2l.ValueChanged -= OnValue;
            p2l = chars[p2lId];
            l2p = chars[l2pId];
            p2l.ProtectionLevel = GattProtectionLevel.EncryptionRequired;
            l2p.ProtectionLevel = GattProtectionLevel.EncryptionRequired;
            p2l.ValueChanged += OnValue;
            var status = await p2l.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            Say($"subscribed: {status}");
        }
        catch (Exception ex) { Say($"subscribe failed: {ex.Message}"); }
        finally { gate.Release(); }
    }

    device.ConnectionStatusChanged += async (d, _) =>
    {
        Say($"connection: {d.ConnectionStatus}");
        if (d.ConnectionStatus == BluetoothConnectionStatus.Connected) await Subscribe();
    };
    await Subscribe();

    var end = DateTime.Now.AddMinutes(minutes);
    for (var n = 1; DateTime.Now < end; n++)
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        if (device.ConnectionStatus != BluetoothConnectionStatus.Connected || l2p is null)
        {
            Say($"waiting | {device.ConnectionStatus}");
            continue;
        }
        try
        {
            var result = await l2p.WriteValueWithResultAsync(Bytes($"ping {n}"), GattWriteOption.WriteWithResponse);
            Say(result.Status == GattCommunicationStatus.Success ? $"-> ping {n}" : $"-> ping {n}: {result.Status} (protocol error {result.ProtocolError})");
        }
        catch (Exception ex) { Say($"-> ping {n} failed: {ex.Message}"); }
    }
    return 0;
}

async Task<int> SetRadio(bool on)
{
    var access = await Radio.RequestAccessAsync();
    var radio = (await Radio.GetRadiosAsync()).FirstOrDefault(r => r.Kind == RadioKind.Bluetooth);
    if (radio is null) { Say($"no Bluetooth radio (access {access})"); return 4; }
    var result = await radio.SetStateAsync(on ? RadioState.On : RadioState.Off);
    Say($"radio '{radio.Name}': {result} | now {radio.State}");
    return result == RadioAccessStatus.Allowed ? 0 : 5;
}

async Task<int> Unpair(string? id)
{
    id ??= File.Exists(deviceFile) ? File.ReadAllText(deviceFile).Trim() : null;
    if (id is null) { Say("nothing remembered"); return 0; }
    using var device = await BluetoothLEDevice.FromIdAsync(id);
    if (device is null) { Say("device not found"); return 4; }
    var result = await device.DeviceInformation.Pairing.UnpairAsync();
    Say($"unpair '{device.Name}': {result.Status}");
    File.Delete(deviceFile);
    return 0;
}

async Task<int> UnpairClassic(string hex)
{
    using var device = await BluetoothDevice.FromBluetoothAddressAsync(Convert.ToUInt64(hex, 16));
    if (device is null) { Say($"no Classic device {hex}"); return 4; }
    var result = await device.DeviceInformation.Pairing.UnpairAsync();
    Say($"unpair '{device.Name}': {result.Status}");
    return 0;
}

async Task<Dictionary<Guid, GattCharacteristic>?> Characteristics(BluetoothLEDevice device)
{
    var services = await device.GetGattServicesForUuidAsync(serviceId, BluetoothCacheMode.Uncached);
    if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
    {
        Say($"CARBON service: {services.Status} | {services.Services.Count} found");
        return null;
    }
    var result = await services.Services[0].GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
    if (result.Status != GattCommunicationStatus.Success) { Say($"characteristics: {result.Status}"); return null; }
    return result.Characteristics.ToDictionary(c => c.Uuid);
}

async Task<string> Read(GattCharacteristic characteristic)
{
    try
    {
        var result = await characteristic.ReadValueAsync(BluetoothCacheMode.Uncached);
        return result.Status == GattCommunicationStatus.Success
            ? Text(result.Value)
            : $"({result.Status}, protocol error {result.ProtocolError})";
    }
    catch (Exception ex) { return $"(failed: {ex.Message})"; }
}

static string Text(IBuffer buffer)
{
    var bytes = new byte[buffer.Length];
    DataReader.FromBuffer(buffer).ReadBytes(bytes);
    return Encoding.UTF8.GetString(bytes);
}

static IBuffer Bytes(string text)
{
    var writer = new DataWriter();
    writer.WriteBytes(Encoding.UTF8.GetBytes(text));
    return writer.DetachBuffer();
}
