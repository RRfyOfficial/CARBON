using System.IO;
using System.Text.Json;

namespace Carbon.Companion;

/// <summary>
/// %LOCALAPPDATA%\CARBON\settings.json (SPEC 10). No secrets: the pairing keys live in the Windows
/// Bluetooth bond; this only remembers which device is the paired phone.
/// </summary>
public sealed class CompanionSettings
{
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CARBON");
    private static readonly string FilePath = Path.Combine(Folder, "settings.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public bool AllowAutopaste { get; set; } = true;
    public bool LaunchAtLogin { get; set; } = true;
    public bool Toasts { get; set; } = true;
    /// <summary>This install's id, sent in hello (PROTOCOL.md Section 2).</summary>
    public string LaptopId { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    /// <summary>The name the phone shows; the computer name unless set by hand.</summary>
    public string? LaptopName { get; set; }
    public string? PairedDeviceId { get; set; }
    public string? PairedPhoneName { get; set; }

    [System.Text.Json.Serialization.JsonIgnore]
    public string EffectiveLaptopName => string.IsNullOrWhiteSpace(LaptopName) ? Environment.MachineName.ToUpperInvariant() : LaptopName;

    public static CompanionSettings Load(Action<string> log)
    {
        try
        {
            if (File.Exists(FilePath) && JsonSerializer.Deserialize<CompanionSettings>(File.ReadAllText(FilePath), Json) is { } saved)
                return saved;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            log($"settings unreadable, starting fresh: {ex.Message}");
        }
        var fresh = new CompanionSettings();
        fresh.Save();
        return fresh;
    }

    public void Save()
    {
        Directory.CreateDirectory(Folder);
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, Json));
        File.Move(temporary, FilePath, overwrite: true);
    }
}
