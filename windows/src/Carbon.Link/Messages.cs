using System.Text.Json;

namespace Carbon.Link;

/// <summary>Once per connection, both directions (laptop first, the phone answers).</summary>
public sealed record Hello(int Proto, string Id, string Name);

/// <summary>Phone → laptop. Mode is "clipboard" or "autopaste"; Ts is Unix milliseconds.</summary>
public sealed record Clip(string Id, long Ts, string Mode, string Text, string? Html)
{
    public bool WantsAutopaste => Mode == "autopaste";
}

/// <summary>Laptop → phone. Result is one of <see cref="AckResult"/>.</summary>
public sealed record Ack(string Id, string Result, string? Detail = null);

public static class AckResult
{
    public const string Copied = "copied";
    public const string Pasted = "pasted";
    public const string PasteBlocked = "paste_blocked";
    public const string AutopasteDisabled = "autopaste_disabled";
    public const string Error = "error";
}

/// <summary>
/// PROTOCOL.md Section 5: UTF-8 JSON with "v": 1 and a "type". Unknown types, unknown fields and
/// other versions are ignored (Decode returns null).
/// </summary>
public static class Messages
{
    public static byte[] Encode(Hello hello) => Write(w =>
    {
        w.WriteString("type", "hello");
        w.WriteNumber("proto", hello.Proto);
        w.WriteString("id", hello.Id);
        w.WriteString("name", hello.Name);
    });

    public static byte[] Encode(Clip clip) => Write(w =>
    {
        w.WriteString("type", "clip");
        w.WriteString("id", clip.Id);
        w.WriteNumber("ts", clip.Ts);
        w.WriteString("mode", clip.Mode);
        w.WriteString("text", clip.Text);
        if (clip.Html is null) w.WriteNull("html"); else w.WriteString("html", clip.Html);
    });

    public static byte[] Encode(Ack ack) => Write(w =>
    {
        w.WriteString("type", "ack");
        w.WriteString("id", ack.Id);
        w.WriteString("result", ack.Result);
        if (ack.Detail is null) w.WriteNull("detail"); else w.WriteString("detail", ack.Detail);
    });

    /// <summary>A <see cref="Hello"/>, <see cref="Clip"/> or <see cref="Ack"/>, or null for anything else.</summary>
    public static object? Decode(ReadOnlySpan<byte> utf8)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("v", out var v) || v.ValueKind != JsonValueKind.Number || v.GetInt32() != 1) return null;
            return Str(root, "type") switch
            {
                "hello" when Int(root, "proto") is { } proto && Str(root, "id") is { } id && Str(root, "name") is { } name
                    => new Hello(proto, id, name),
                "clip" when Str(root, "id") is { } id && Long(root, "ts") is { } ts && Str(root, "mode") is { } mode && Str(root, "text") is { } text
                    => new Clip(id, ts, mode, text, Str(root, "html")),
                "ack" when Str(root, "id") is { } id && Str(root, "result") is { } result
                    => new Ack(id, result, Str(root, "detail")),
                _ => null,
            };
        }
        catch (JsonException)
        {
            return null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static byte[] Write(Action<Utf8JsonWriter> body)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("v", 1);
            body(writer);
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    private static string? Str(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int? Int(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var n) ? n : null;

    private static long? Long(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var n) ? n : null;

    public static string Describe(object message) => message switch
    {
        Hello h => $"hello proto {h.Proto} '{h.Name}'",
        Clip c => $"clip {c.Text.Length} chars {c.Mode}",
        Ack a => $"ack {a.Result}",
        _ => message.GetType().Name,
    };
}
