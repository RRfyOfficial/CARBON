using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Carbon.Output;

public enum PasteOutcome
{
    Pasted,
    /// <summary>The foreground window runs elevated and the companion doesn't: Windows would drop the keys.</summary>
    Blocked,
}

/// <summary>
/// SPEC 10, autopaste: wait 60 ms after the clipboard is set, wait up to 300 ms for physically held
/// modifiers to be released, then send Ctrl+V with SendInput. Reports Blocked instead when the
/// foreground window is elevated and the companion isn't (Windows silently blocks that input).
/// </summary>
public static class AutoPaster
{
    public static async Task<PasteOutcome> PasteAsync()
    {
        await Task.Delay(60);
        var deadline = Environment.TickCount64 + 300;
        while (ModifierHeld() && Environment.TickCount64 < deadline) await Task.Delay(15);
        if (ForegroundIsElevated() && !IsElevated(Native.GetCurrentProcess(), ownsHandle: false)) return PasteOutcome.Blocked;

        var inputs = new[]
        {
            Key(Native.VK_CONTROL, up: false),
            Key(Native.VK_V, up: false),
            Key(Native.VK_V, up: true),
            Key(Native.VK_CONTROL, up: true),
        };
        var sent = Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>());
        if (sent != inputs.Length) throw new Win32Exception(Marshal.GetLastWin32Error(), "SendInput sent " + sent + " of 4 key events");
        return PasteOutcome.Pasted;
    }

    private static bool ModifierHeld() =>
        new[] { Native.VK_SHIFT, Native.VK_CONTROL, Native.VK_MENU, Native.VK_LWIN, Native.VK_RWIN }
            .Any(key => (Native.GetAsyncKeyState(key) & 0x8000) != 0);

    /// <summary>Best effort. A process we may not even query is treated as elevated.</summary>
    private static bool ForegroundIsElevated()
    {
        var window = Native.GetForegroundWindow();
        if (window == IntPtr.Zero) return false;
        Native.GetWindowThreadProcessId(window, out var processId);
        if (processId == 0) return false;
        var process = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) return true;
        return IsElevated(process, ownsHandle: true);
    }

    private static bool IsElevated(IntPtr process, bool ownsHandle)
    {
        try
        {
            if (!Native.OpenProcessToken(process, Native.TOKEN_QUERY, out var token)) return ownsHandle;
            try
            {
                var size = Marshal.SizeOf<int>();
                var buffer = Marshal.AllocHGlobal(size);
                try
                {
                    if (!Native.GetTokenInformation(token, Native.TokenElevation, buffer, size, out _)) return ownsHandle;
                    return Marshal.ReadInt32(buffer) != 0;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                Native.CloseHandle(token);
            }
        }
        finally
        {
            if (ownsHandle) Native.CloseHandle(process);
        }
    }

    private static Native.INPUT Key(ushort virtualKey, bool up) => new()
    {
        type = Native.INPUT_KEYBOARD,
        u = new Native.InputUnion
        {
            ki = new Native.KEYBDINPUT { wVk = virtualKey, dwFlags = up ? Native.KEYEVENTF_KEYUP : 0 },
        },
    };

    private static class Native
    {
        public const uint INPUT_KEYBOARD = 1;
        public const uint KEYEVENTF_KEYUP = 0x0002;
        public const ushort VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_V = 0x56;
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        public const uint TOKEN_QUERY = 0x0008;
        public const int TokenElevation = 20;

        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            public InputUnion u;
        }

        // The union must include MOUSEINPUT, the largest member, so INPUT has the size SendInput expects.
        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint SendInput(uint count, INPUT[] inputs, int size);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int key);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
