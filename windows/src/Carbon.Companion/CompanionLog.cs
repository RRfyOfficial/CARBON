using System.Diagnostics;
using System.IO;

namespace Carbon.Companion;

/// <summary>
/// %LOCALAPPDATA%\CARBON\logs\companion-yyyyMMdd.log, one file a day, the newest 7 kept.
/// Lengths, states and results only: never clip text.
/// </summary>
public sealed class CompanionLog
{
    private readonly string folder = Path.Combine(CompanionSettings.Folder, "logs");
    private readonly object gate = new();

    public CompanionLog()
    {
        Directory.CreateDirectory(folder);
        foreach (var old in Directory.GetFiles(folder, "companion-*.log").OrderDescending().Skip(7))
        {
            try { File.Delete(old); } catch (IOException) { }
        }
    }

    public void Write(string text)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}  {text}";
        Debug.WriteLine(line);
        lock (gate)
        {
            try
            {
                File.AppendAllText(Path.Combine(folder, $"companion-{DateTime.Now:yyyyMMdd}.log"), line + Environment.NewLine);
            }
            catch (IOException)
            {
            }
        }
    }
}
