namespace Carbon.Link;

/// <summary>
/// The last 50 clip ids and their results (PROTOCOL.md Section 6): a repeated clip is acked again
/// with the same result but never pasted twice.
/// </summary>
public sealed class ClipDedupe(int capacity = Protocol.RememberedClips)
{
    private readonly Queue<string> order = new();
    private readonly Dictionary<string, string> results = [];

    public bool TryGet(string id, out string result) => results.TryGetValue(id, out result!);

    public void Remember(string id, string result)
    {
        if (results.ContainsKey(id))
        {
            results[id] = result;
            return;
        }
        results[id] = result;
        order.Enqueue(id);
        while (order.Count > capacity)
            results.Remove(order.Dequeue());
    }
}
