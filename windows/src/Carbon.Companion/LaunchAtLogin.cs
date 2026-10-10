using Microsoft.Win32;

namespace Carbon.Companion;

/// <summary>
/// The HKCU Run entry (SPEC 10). Development builds (running from bin\) never register, so trying
/// the companion from source doesn't leave a startup entry pointing into the repo.
/// </summary>
public static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "CARBON Companion";

    public static bool IsDevelopmentBuild =>
        Environment.ProcessPath is { } path && path.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase);

    public static void Apply(bool enabled, Action<string> log)
    {
        if (IsDevelopmentBuild)
        {
            log("development build: launch at login not registered");
            return;
        }
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && Environment.ProcessPath is { } path)
            key.SetValue(ValueName, $"\"{path}\"");
        else
            key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
