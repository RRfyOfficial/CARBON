using System.Text.Json;
using Carbon.Link;

namespace Carbon.Link.Tests;

/// <summary>protocol/test-vectors/framing.json, from tools/gen_test_vectors.py: byte for byte.</summary>
public class FramingVectorTests
{
    private static readonly JsonElement Vectors =
        JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "framing.json"))).RootElement;

    public static IEnumerable<object[]> SplitCases() =>
        Vectors.GetProperty("split").EnumerateArray().Select(c => new object[] { c.GetProperty("name").GetString()! });

    public static IEnumerable<object[]> ReassembleCases() =>
        Vectors.GetProperty("reassemble").EnumerateArray().Select(c => new object[] { c.GetProperty("name").GetString()! });

    [Theory]
    [MemberData(nameof(SplitCases))]
    public void SplitMatchesTheVector(string name)
    {
        var c = Case("split", name);
        var frames = Framing.Split(Convert.FromHexString(c.GetProperty("message").GetString()!),
                                   (ushort)c.GetProperty("msgId").GetInt32(), c.GetProperty("chunkSize").GetInt32());
        Assert.Equal(Hexes(c.GetProperty("frames")), frames.Select(Convert.ToHexString));
    }

    [Theory]
    [MemberData(nameof(ReassembleCases))]
    public void ReassemblyMatchesTheVector(string name)
    {
        var c = Case("reassemble", name);
        var reassembler = new Reassembler();
        var messages = new List<string>();
        foreach (var frame in Hexes(c.GetProperty("frames")))
        {
            if (reassembler.Add(Convert.FromHexString(frame)) is { } message)
                messages.Add(Convert.ToHexString(message));
        }
        Assert.Equal(Hexes(c.GetProperty("messages")), messages);
    }

    [Fact]
    public void TheVectorsAreThere() =>
        Assert.True(Vectors.GetProperty("split").GetArrayLength() >= 8 && Vectors.GetProperty("reassemble").GetArrayLength() >= 8);

    private static JsonElement Case(string kind, string name) =>
        Vectors.GetProperty(kind).EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);

    // Upper-case hex, like Convert.ToHexString.
    private static List<string> Hexes(JsonElement array) =>
        array.EnumerateArray().Select(e => e.GetString()!.ToUpperInvariant()).ToList();
}
