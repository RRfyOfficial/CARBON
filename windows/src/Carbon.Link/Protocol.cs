namespace Carbon.Link;

/// <summary>Constants from protocol/PROTOCOL.md (the link's source of truth).</summary>
public static class Protocol
{
    public const int Version = 1;

    public static readonly Guid Service = Guid.Parse("5D7FCEF4-D1AA-46A6-B187-DF5AF19C5BC5");
    public static readonly Guid Info = Guid.Parse("C34B4E97-BD2A-4254-A253-B8557272FEBE");
    /// <summary>Notify, phone → laptop: hello, clip.</summary>
    public static readonly Guid P2L = Guid.Parse("FA6817D4-2B2E-4AD3-ABB0-8981F0A8C674");
    /// <summary>Write with response, laptop → phone: hello, ack.</summary>
    public static readonly Guid L2P = Guid.Parse("4414751E-1E20-4530-AA11-46485950207B");

    public const int HeaderSize = 6;
    public const int MinChunk = 14;
    public const int MaxChunk = 506;
    public const int MaxMessage = 65_536;
    public static readonly TimeSpan PartialTimeout = TimeSpan.FromSeconds(5);
    public const int RememberedClips = 50;
}
