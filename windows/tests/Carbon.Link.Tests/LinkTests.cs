using System.Text;
using Carbon.Link;

namespace Carbon.Link.Tests;

public class MessageTests
{
    [Fact]
    public void HelloAndAckRoundTrip()
    {
        var hello = new Hello(1, "6F1C2D3E-0000-4000-8000-000000000001", "ZEPHYRUS-G16");
        Assert.Equal(hello, Messages.Decode(Messages.Encode(hello)));
        var ack = new Ack("0F8C2E2A-5B1D-4C55-9C1E-3D6A0B7E9F10", AckResult.Pasted);
        Assert.Equal(ack, Messages.Decode(Messages.Encode(ack)));
    }

    [Fact]
    public void AClipFromThePhoneDecodes()
    {
        var json = """{"v":1,"type":"clip","id":"A","ts":1760030000000,"mode":"autopaste","text":"Week 6\n• Recruit","html":null,"extra":true}""";
        var clip = Assert.IsType<Clip>(Messages.Decode(Encoding.UTF8.GetBytes(json)));
        Assert.Equal("Week 6\n• Recruit", clip.Text);
        Assert.True(clip.WantsAutopaste);
        Assert.Null(clip.Html);
    }

    [Fact]
    public void AckEncodingKeepsNonAsciiAndHasAllFields()
    {
        var text = Encoding.UTF8.GetString(Messages.Encode(new Ack("x", AckResult.Error, "café")));
        Assert.Equal("""{"v":1,"type":"ack","id":"x","result":"error","detail":"café"}""", text);
    }

    [Theory]
    [InlineData("""{"v":2,"type":"ack","id":"x","result":"copied"}""")]   // other version
    [InlineData("""{"v":1,"type":"ping","ts":1}""")]                      // unknown type
    [InlineData("""{"v":1,"type":"clip","id":"x"}""")]                     // missing fields
    [InlineData("""not json""")]
    [InlineData("""[1,2]""")]
    public void AnythingElseIsIgnored(string json) =>
        Assert.Null(Messages.Decode(Encoding.UTF8.GetBytes(json)));
}

public class DedupeTests
{
    [Fact]
    public void ARepeatedClipGetsTheSameResult()
    {
        var dedupe = new ClipDedupe();
        dedupe.Remember("a", AckResult.Pasted);
        Assert.True(dedupe.TryGet("a", out var result));
        Assert.Equal(AckResult.Pasted, result);
        Assert.False(dedupe.TryGet("b", out _));
    }

    [Fact]
    public void OnlyTheLastFiftyAreRemembered()
    {
        var dedupe = new ClipDedupe();
        for (var i = 0; i < 51; i++) dedupe.Remember($"clip{i}", AckResult.Copied);
        Assert.False(dedupe.TryGet("clip0", out _));
        Assert.True(dedupe.TryGet("clip1", out _));
        Assert.True(dedupe.TryGet("clip50", out _));
    }
}

public class ReassemblerTests
{
    [Fact]
    public void APartialMessageExpiresAfterFiveSeconds()
    {
        var now = new DateTime(2026, 10, 10, 12, 0, 0, DateTimeKind.Utc);
        var reassembler = new Reassembler(() => now);
        var frames = Framing.Split(new byte[40], 1, 20);
        Assert.Null(reassembler.Add(frames[0]));
        now += TimeSpan.FromSeconds(6);
        Assert.Null(reassembler.Add(frames[1]));   // the first half was dropped
    }

    [Fact]
    public void SplitThenReassembleIsTheIdentity()
    {
        var message = Encoding.UTF8.GetBytes(new string('x', 5000) + " · done");
        var reassembler = new Reassembler();
        byte[]? result = null;
        foreach (var frame in Framing.Split(message, 42, 180)) result = reassembler.Add(frame) ?? result;
        Assert.Equal(message, result);
    }

    [Fact]
    public void ChunkSizeStaysInBounds()
    {
        Assert.Equal(Protocol.MinChunk, Framing.ChunkSize(10));
        Assert.Equal(179, Framing.ChunkSize(185));
        Assert.Equal(Protocol.MaxChunk, Framing.ChunkSize(2000));
    }
}
