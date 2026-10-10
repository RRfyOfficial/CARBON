using System.Buffers.Binary;

namespace Carbon.Link;

/// <summary>
/// PROTOCOL.md Section 4: every message travels as frames with a 6-byte little-endian header
/// (msgId, index, count), then a chunk.
/// </summary>
public static class Framing
{
    public static IReadOnlyList<byte[]> Split(ReadOnlySpan<byte> message, ushort msgId, int chunkSize)
    {
        if (message.Length > Protocol.MaxMessage)
            throw new ArgumentException($"message is {message.Length} bytes; the limit is {Protocol.MaxMessage}", nameof(message));
        if (chunkSize is < Protocol.MinChunk or > Protocol.MaxChunk)
            throw new ArgumentOutOfRangeException(nameof(chunkSize), chunkSize, $"must be {Protocol.MinChunk}–{Protocol.MaxChunk}");

        var count = Math.Max(1, (message.Length + chunkSize - 1) / chunkSize);
        var frames = new List<byte[]>(count);
        for (var index = 0; index < count; index++)
        {
            var start = index * chunkSize;
            var length = Math.Min(chunkSize, message.Length - start);
            var frame = new byte[Protocol.HeaderSize + length];
            BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(0), msgId);
            BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(2), (ushort)index);
            BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(4), (ushort)count);
            message.Slice(start, length).CopyTo(frame.AsSpan(Protocol.HeaderSize));
            frames.Add(frame);
        }
        return frames;
    }

    /// <summary>The chunk size for a negotiated payload size, kept inside the protocol's bounds.</summary>
    public static int ChunkSize(int payloadBytes) => Math.Clamp(payloadBytes - Protocol.HeaderSize, Protocol.MinChunk, Protocol.MaxChunk);
}

/// <summary>
/// In-order reassembly per msgId (PROTOCOL.md Section 4). Index 0 starts a message; any other frame
/// must be the next expected one with the same count, or the partial message is dropped.
/// Not thread-safe: feed it from one place.
/// </summary>
public sealed class Reassembler(Func<DateTime>? clock = null)
{
    private sealed class Partial
    {
        public required ushort Count;
        public required ushort Next;
        public required DateTime Started;
        public readonly MemoryStream Data = new();
    }

    private readonly Dictionary<ushort, Partial> partial = [];
    private readonly Func<DateTime> now = clock ?? (() => DateTime.UtcNow);

    /// <summary>Feeds one frame. Returns the message it completes, or null.</summary>
    public byte[]? Add(ReadOnlySpan<byte> frame)
    {
        DropStale();
        if (frame.Length < Protocol.HeaderSize) return null;
        var msgId = BinaryPrimitives.ReadUInt16LittleEndian(frame);
        var index = BinaryPrimitives.ReadUInt16LittleEndian(frame[2..]);
        var count = BinaryPrimitives.ReadUInt16LittleEndian(frame[4..]);
        if (count == 0 || index >= count) return null;

        Partial message;
        if (index == 0)
        {
            message = new Partial { Count = count, Next = 1, Started = now() };
            partial[msgId] = message;
        }
        else
        {
            if (!partial.TryGetValue(msgId, out var existing) || existing.Count != count || existing.Next != index)
            {
                partial.Remove(msgId);
                return null;
            }
            message = existing;
            message.Next++;
        }

        message.Data.Write(frame[Protocol.HeaderSize..]);
        if (message.Data.Length > Protocol.MaxMessage)
        {
            partial.Remove(msgId);
            return null;
        }
        if (message.Next < message.Count) return null;
        partial.Remove(msgId);
        return message.Data.ToArray();
    }

    /// <summary>Forgets everything, e.g. after a reconnect.</summary>
    public void Reset() => partial.Clear();

    private void DropStale()
    {
        var cutoff = now() - Protocol.PartialTimeout;
        foreach (var stale in partial.Where(p => p.Value.Started < cutoff).Select(p => p.Key).ToList())
            partial.Remove(stale);
    }
}
