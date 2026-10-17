using System.Runtime.InteropServices;
using System.Windows;

namespace Carbon.Output;

/// <summary>
/// Unicode text on the clipboard, retried up to 10 times 50 ms apart while another app
/// holds it open. Call on the STA (UI) thread. The previous contents are not restored.
/// </summary>
public static class ClipboardWriter
{
    public static async Task<bool> TrySetTextAsync(string text)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        for (var attempt = 1; attempt <= 10; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(data, copy: true);
                return true;
            }
            catch (ExternalException) when (attempt < 10)
            {
                await Task.Delay(50);
            }
            catch (ExternalException)
            {
                return false;
            }
        }
        return false;
    }
}
