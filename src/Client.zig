//! Doc comments mostly based on https://mpd.readthedocs.io/en/latest/protocol.html
//!
//! To avoid confusion, in zmpd "queue" means the queue (AKA "current playlist"), while "playlist" means a stored
//! playlist, see the note at https://mpd.readthedocs.io/en/latest/protocol.html#the-queue
//!
//! Song positions are 0-based.

// TODO: document MPD protocol version requirements for all commands, maybe add assertions

// TODO: command lists

const std = @import("std");

const zmpd = @import("zmpd.zig");
pub const tags = @import("tags.zig");
const FakeClient = @import("FakeClient.zig");

writer: *std.Io.Writer,
reader: *std.Io.Reader,
mpd_version: std.SemanticVersion,
/// MPD can return different errors with the same error code, but Zig doesn't support error payloads. This variable is
/// a workaround to allow you to see what actually went wrong.
// TODO: parse all those errors and make error sets
last_error_msg: ?[]const u8 = null,

pub const ResponseError =
    zmpd.ProtocolError ||
    std.Io.Writer.Error ||
    std.Io.Reader.DelimiterError ||
    std.fmt.ParseIntError ||
    std.mem.Allocator.Error ||
    error{UnexpectedResponse};

const Client = @This();

pub const InitError = std.Io.Writer.Error || std.Io.Reader.DelimiterError || error{ MpdError, BufSizeTooSmall };

pub const InitOptions = struct {
    /// Size of allocated writer/reader buffers for communicating with the server. If you somehow get `StreamTooLong`
    /// errors, try increasing this value.
    ///
    /// The reference MPD implementation (as of version 0.24) will not accept values smaller than 64.
    buffer_size: u32 = 1024,
    password: ?[]const u8 = null,
};

/// Use `zmpd.connect` or `zmpd.Connection.init` if you just want to use `std.net.Stream`
pub fn init(writer: *std.Io.Writer, reader: *std.Io.Reader, options: InitOptions) InitError!Client {
    const response = try reader.takeDelimiterInclusive('\n');
    if (!std.mem.startsWith(u8, response, "OK MPD"))
        // TODO: what can this error be?
        return error.MpdError;

    var client = Client{
        .writer = writer,
        .reader = reader,
        .mpd_version = std.SemanticVersion.parse(std.mem.trimEnd(u8, response[7..], "\n")) catch
            return error.MpdError,
    };

    try writer.print("binarylimit {}\n", .{options.buffer_size});
    try writer.flush();
    client.checkResponse() catch return error.BufSizeTooSmall;

    return client;
}

pub fn nextLine(self: *Client) ResponseError!?zmpd.KV {
    while (true) {
        const line = try self.reader.takeDelimiterExclusive('\n');

        if (std.mem.eql(u8, line, "OK")) return null;
        if (std.mem.startsWith(u8, line, "ACK")) {
            @branchHint(.unlikely);
            self.last_error_msg = line[std.mem.lastIndexOfScalar(u8, line, '}').? + 2 ..];
            // https://github.com/MusicPlayerDaemon/MPD/blob/master/src/protocol/Ack.hxx
            return switch (try std.fmt.parseUnsigned(u8, line[5..std.mem.indexOfScalar(u8, line, '@').?], 10)) {
                1 => zmpd.ProtocolError.NotList,
                2 => zmpd.ProtocolError.Arg,
                3 => zmpd.ProtocolError.Password,
                4 => zmpd.ProtocolError.Permission,
                50 => zmpd.ProtocolError.NoExist,
                51 => zmpd.ProtocolError.PlaylistMax,
                52 => zmpd.ProtocolError.System,
                53 => zmpd.ProtocolError.PlaylistLoad,
                54 => zmpd.ProtocolError.UpdateAlready,
                55 => zmpd.ProtocolError.PlayerSync,
                56 => zmpd.ProtocolError.Exist,
                else => zmpd.ProtocolError.Unknown,
            };
        }

        var it = std.mem.splitSequence(u8, line, ": ");
        const key = it.first();
        const value = it.rest();
        if (key.len != 0 and value.len != 0)
            return .{ .key = key, .value = value };
    }
}

/// This is only used when handling raw daemon commands and their responses. Always prefer using functions in `Client`
/// for interacting with the daemon as they already propagate errors properly.
///
/// This is intended for commands that don't respond with an object (play, pause, setvol, etc) or where we ignore the
/// response. In such cases you should call this function right after calling `sendCommand()` or
/// `sendCommandWithArgs()`, otherwise errors from the daemon will be left unhandled.
///
/// The idea seems a bit stupid, but commands that respond with an object (status, stats, etc) only have an `OK` after
/// the response, so it's impossible to check if such a command succeeded without also trying to read the rest of the
/// response.
pub fn checkResponse(self: *Client) !void {
    if (try self.nextLine()) |_| return error.UnexpectedResponse;
}

test checkResponse {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse("OK\n");
    try client.checkResponse();

    fake.setResponse("ACK [5@0] {} unknown command \"test\"\n");
    try std.testing.expectError(zmpd.ProtocolError.Unknown, client.checkResponse());
    try std.testing.expectEqualStrings("unknown command \"test\"", client.last_error_msg.?);
}

fn writeQuoted(self: *Client, bytes: []const u8) std.Io.Writer.Error!void {
    try self.writer.writeByte('"');
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, index, '"')) |i| {
        try self.writer.writeAll(bytes[index..i]);
        try self.writer.writeAll("\\\"");
        index = i + 1;
    }
    try self.writer.writeAll(bytes[index..]);
    try self.writer.writeByte('"');
}

/// Assert that the daemon's version is equal or higher.
///
/// Only has an effect in Debug mode when `assert_version` is enabled in the build options.
pub fn assertVersion(self: *const Client, version: std.SemanticVersion) void {
    if (zmpd.options.assert_version) {
        if (!self.mpd_version.order(version).compare(.gte))
            std.debug.panic("MPD version {f} is required, but {f} is running", .{ version, self.mpd_version });
    }
}

pub const AudioFormat = struct {
    sample_rate: u32,
    bits: u8,
    channels: u8,

    pub fn parse(value: []const u8) std.fmt.ParseIntError!AudioFormat {
        var audio = std.mem.tokenizeScalar(u8, value, ':');
        return .{
            .sample_rate = try std.fmt.parseUnsigned(u32, audio.next().?, 10),
            .bits = try std.fmt.parseUnsigned(u8, audio.next().?, 10),
            .channels = try std.fmt.parseUnsigned(u8, audio.next().?, 10),
        };
    }

    test parse {
        try std.testing.expectEqualDeep(AudioFormat{
            .sample_rate = 44100,
            .bits = 16,
            .channels = 2,
        }, parse("44100:16:2"));
    }
};

pub const FloatRange = struct {
    /// Range start in seconds
    start: f32,
    /// Range end in seconds, null means until the end of the file
    end: ?f32,

    pub fn parse(value: []const u8) std.fmt.ParseFloatError!FloatRange {
        var it = std.mem.splitScalar(u8, value, '-');
        return .{
            .start = try std.fmt.parseFloat(f32, it.next().?),
            .end = if (it.next()) |v| try std.fmt.parseFloat(f32, v) else null,
        };
    }

    pub fn format(self: FloatRange, writer: *std.Io.Writer) !void {
        if (self.end) |end|
            try writer.print("{d}:{d}", .{ self.start, end })
        else
            try writer.print("{}:", .{self.start});
    }
};

// TODO: what's actually optional here?
pub const Song = struct {
    arena: std.heap.ArenaAllocator,

    /// File path relative to MPD library root
    file: ?[]const u8 = null,
    /// Song duration in seconds
    duration: ?f32 = null,
    /// When the queue item is just a portion of a file
    range: ?FloatRange = null,
    /// ISO-8601 date
    last_modified: ?[]const u8 = null,
    /// ISO-8601 date
    added: ?[]const u8 = null,
    /// Current position in the queue
    pos: ?u32 = null,
    song_id: ?u32 = null,
    /// Higher priority means this song will be played first when random mode is enabled. All songs have 0 priority by default
    priority: ?u8 = null,
    format: ?AudioFormat = null,

    tags: tags.Tags,

    pub inline fn deinit(self: *const Song) void {
        self.arena.deinit();
        self.tags.deinit();
    }

    fn parseKV(res: *Song, kv: zmpd.KV, comptime check_file: bool) ResponseError!void {
        const alloc = res.arena.allocator();

        if (check_file) {
            if (std.mem.eql(u8, kv.key, "file")) {
                res.file = try alloc.dupe(u8, kv.value);
                return;
            }
        }

        if (std.mem.eql(u8, kv.key, "duration"))
            res.duration = try std.fmt.parseFloat(f32, kv.value)
        else if (std.mem.eql(u8, kv.key, "Range"))
            res.range = try .parse(kv.value)
        else if (std.mem.eql(u8, kv.key, "Last-Modified"))
            res.last_modified = try alloc.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Added"))
            res.added = try alloc.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Pos"))
            res.pos = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "Id"))
            res.song_id = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "Prio"))
            res.priority = try std.fmt.parseUnsigned(u8, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "Format"))
            res.format = try .parse(kv.value)
        else
            try res.tags.parseTag(kv);
    }

    pub fn parse(client: *Client, allocator: std.mem.Allocator) ResponseError!Song {
        var res = Song{
            .arena = .init(allocator),
            .tags = .{ .arena = .init(allocator) },
        };

        while (try client.nextLine()) |kv|
            try res.parseKV(kv, true);

        return res;
    }

    pub const Iterator = struct {
        allocator: std.mem.Allocator,
        client: *Client,
        last_file: ?[]const u8 = null,
        last_kv: ?zmpd.KV,

        pub fn init(allocator: std.mem.Allocator, client: *Client) ResponseError!Iterator {
            return .{
                .allocator = allocator,
                .client = client,
                .last_kv = try client.nextLine(),
            };
        }

        /// Caller must call `Song.deinit` on each result
        pub fn next(self: *Iterator) ResponseError!?Song {
            if (self.last_kv == null) return null;

            var current = Song{
                .arena = .init(self.allocator),
                .tags = .{ .arena = .init(self.allocator) },
            };
            const allocator = current.arena.allocator();

            if (self.last_file) |last_file|
                current.file = try allocator.dupe(u8, last_file);

            while (self.last_kv) |kv| {
                if (std.mem.eql(u8, kv.key, "file")) {
                    if (self.last_file) |last_file| {
                        self.allocator.free(last_file);
                        self.last_file = try self.allocator.dupe(u8, kv.value);
                        self.last_kv = try self.client.nextLine();
                        return current;
                    } else {
                        self.last_file = try self.allocator.dupe(u8, kv.value);
                        current.file = try allocator.dupe(u8, kv.value);
                    }
                } else try current.parseKV(kv, true);

                self.last_kv = try self.client.nextLine();
            }

            return current;
        }

        pub inline fn deinit(self: *const Iterator) void {
            if (self.last_file) |last_file|
                self.allocator.free(last_file);
        }
    };
};

/// Caller must call `Song.deinit` on the result to free strings
pub fn getCurrentSong(self: *Client, allocator: std.mem.Allocator) ResponseError!Song {
    try self.writer.writeAll("currentsong\n");
    try self.writer.flush();
    return .parse(self, allocator);
}

test getCurrentSong {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    // test unicode and repeat values

    fake.setResponse(
        \\file: Gerogerigegege, The/[1990] The Gerogerigegege - パンクの鬼_ TOKYO ANAL DYNAMITE/01-01 - The Gerogerigegege - ロックン・ロール.flac
        \\Last-Modified: 2025-06-08T14:50:47Z
        \\Added: 2025-05-26T14:01:38Z
        \\Format: 44100:16:2
        \\Album: パンクの鬼: TOKYO ANAL DYNAMITE
        \\AlbumArtist: The Gerogerigegege
        \\Artist: The Gerogerigegege
        \\ArtistSort: Gerogerigegege, The
        \\Date: 1990
        \\Disc: 1
        \\Disc: 1
        \\Genre: Grindcore
        \\Label: Vis A Vis Audio Arts
        \\MUSICBRAINZ_ALBUMARTISTID: 5a988ed5-a36b-4af2-9157-0bd09ca9d99c
        \\MUSICBRAINZ_ALBUMID: a372b58a-8b79-4b21-b717-7e32bbbb0f2e
        \\MUSICBRAINZ_ARTISTID: 5a988ed5-a36b-4af2-9157-0bd09ca9d99c
        \\MUSICBRAINZ_RELEASEGROUPID: 2a7ab8ba-ac5a-3090-b159-dc30269e4478
        \\MUSICBRAINZ_RELEASETRACKID: 43c91d37-1b80-36c9-b8e9-b00a0de9150e
        \\MUSICBRAINZ_TRACKID: 4278138d-3d88-490d-9179-3bbf003ec3de
        \\OriginalDate: 1990
        \\Title: ロックン・ロール
        \\Track: 1
        \\Track: 1
        \\Time: 57
        \\duration: 57.133
        \\Pos: 0
        \\Id: 95
        \\OK
    );

    {
        const song = try client.getCurrentSong(std.testing.allocator);
        defer song.deinit();

        try std.testing.expectEqualDeep(
            Song{
                .arena = song.arena,
                .file = "Gerogerigegege, The/[1990] The Gerogerigegege - パンクの鬼_ TOKYO ANAL DYNAMITE/01-01 - The Gerogerigegege - ロックン・ロール.flac",
                .duration = 57.133,
                .last_modified = "2025-06-08T14:50:47Z",
                .added = "2025-05-26T14:01:38Z",
                .pos = 0,
                .song_id = 95,
                .format = .{
                    .sample_rate = 44100,
                    .bits = 16,
                    .channels = 2,
                },
                .tags = .{
                    .arena = song.tags.arena,
                    .artist = "The Gerogerigegege",
                    .artist_sort = "Gerogerigegege, The",
                    .album_artist = "The Gerogerigegege",
                    .album = "パンクの鬼: TOKYO ANAL DYNAMITE",
                    .title = "ロックン・ロール",
                    .track = 1,
                    .disc = 1,
                    .genre = "Grindcore",
                    .date = "1990",
                    .original_date = "1990",
                    .label = "Vis A Vis Audio Arts",
                    .mb_artist_id = "5a988ed5-a36b-4af2-9157-0bd09ca9d99c",
                    .mb_album_artist_id = "5a988ed5-a36b-4af2-9157-0bd09ca9d99c",
                    .mb_album_id = "a372b58a-8b79-4b21-b717-7e32bbbb0f2e",
                    .mb_track_id = "4278138d-3d88-490d-9179-3bbf003ec3de",
                    .mb_release_track_id = "43c91d37-1b80-36c9-b8e9-b00a0de9150e",
                    .mb_release_group_id = "2a7ab8ba-ac5a-3090-b159-dc30269e4478",
                },
            },
            song,
        );
    }

    fake.setResponse(
        \\file: Flume/[2019] Flume - Hi This Is Flume/01-05 - Flume - ╜Φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫.flac
        \\Last-Modified: 2025-08-31T15:30:01Z
        \\Added: 2025-08-31T15:30:02Z
        \\Format: 44100:16:2
        \\Album: Hi This Is Flume
        \\AlbumArtist: Flume
        \\Artist: Flume
        \\Date: 2019-03-20
        \\Disc: 1
        \\Disc: 1
        \\Genre: Electronic
        \\Label: Future Classic
        \\MUSICBRAINZ_ALBUMARTISTID: 35fd8d42-b4a6-4414-9827-8766bd0daa3c
        \\MUSICBRAINZ_ALBUMID: 264dd318-2872-4a2b-bb41-bca626c70e00
        \\MUSICBRAINZ_ARTISTID: 35fd8d42-b4a6-4414-9827-8766bd0daa3c
        \\MUSICBRAINZ_RELEASEGROUPID: dc5e566b-ac5a-4ea6-8faa-82f193b086dd
        \\MUSICBRAINZ_RELEASETRACKID: ab2faaf8-42bb-4d53-acea-6d8867477495
        \\MUSICBRAINZ_TRACKID: 93d0086c-27e7-4206-8722-e4c3c0b6d786
        \\MUSICBRAINZ_WORKID: 7143f660-8214-4684-b76e-ad0015613465
        \\OriginalDate: 2019-03-20
        \\Title: ╜Φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌
        \\Track: 5
        \\Track: 5
        \\Time: 34
        \\duration: 33.567
        \\Pos: 4
        \\Id: 61
        \\OK
    );

    {
        const song = try client.getCurrentSong(std.testing.allocator);
        defer song.deinit();

        try std.testing.expectEqualDeep(
            Song{
                .arena = song.arena,
                .file = "Flume/[2019] Flume - Hi This Is Flume/01-05 - Flume - ╜Φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫.flac",
                .duration = 33.567,
                .last_modified = "2025-08-31T15:30:01Z",
                .added = "2025-08-31T15:30:02Z",
                .pos = 4,
                .song_id = 61,
                .format = .{
                    .sample_rate = 44100,
                    .bits = 16,
                    .channels = 2,
                },
                .tags = .{
                    .arena = song.tags.arena,
                    .artist = "Flume",
                    .album_artist = "Flume",
                    .album = "Hi This Is Flume",
                    .title = "╜Φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌╫§╜φ°⌂▌",
                    .track = 5,
                    .disc = 1,
                    .genre = "Electronic",
                    .date = "2019-03-20",
                    .original_date = "2019-03-20",
                    .label = "Future Classic",
                    .mb_artist_id = "35fd8d42-b4a6-4414-9827-8766bd0daa3c",
                    .mb_album_artist_id = "35fd8d42-b4a6-4414-9827-8766bd0daa3c",
                    .mb_album_id = "264dd318-2872-4a2b-bb41-bca626c70e00",
                    .mb_track_id = "93d0086c-27e7-4206-8722-e4c3c0b6d786",
                    .mb_release_track_id = "ab2faaf8-42bb-4d53-acea-6d8867477495",
                    .mb_release_group_id = "dc5e566b-ac5a-4ea6-8faa-82f193b086dd",
                    .mb_work_id = "7143f660-8214-4684-b76e-ad0015613465",
                },
            },
            song,
        );
    }

    fake.setResponse(
        \\file: Aphex Twin/[1999] Aphex Twin - Windowlicker/01-02 - Aphex Twin - ∆Mᵢ⁻¹ = −∂ ∑ Dᵢ[n] [∑ Fⱼᵢ[n−1] + F extᵢ[n⁻¹]].mp3
        \\Last-Modified: 2025-06-08T12:51:45Z
        \\Added: 2025-05-25T22:06:52Z
        \\Format: 44100:16:2
        \\Artist: Aphex Twin
        \\AlbumArtist: Aphex Twin
        \\ArtistSort: Aphex Twin
        \\Title: ∆Mᵢ⁻¹ = −∂ ∑ Dᵢ[n] [∑ Fⱼᵢ[n−1] + F extᵢ[n⁻¹]]
        \\Album: Windowlicker
        \\Track: 2
        \\Date: 1999-03-22
        \\OriginalDate: 1999-03-22
        \\Genre: Idm, Electronic, Ambient
        \\Composer: Richard D. James
        \\Disc: 1
        \\Label: Warp
        \\MUSICBRAINZ_TRACKID: 109bba47-f0b9-42b3-91c4-48eb7e0ebc55
        \\Time: 348
        \\duration: 347.913
        \\Pos: 1
        \\Id: 45
        \\OK
    );

    {
        const song = try client.getCurrentSong(std.testing.allocator);
        defer song.deinit();

        try std.testing.expectEqualDeep(
            Song{
                .arena = song.arena,
                .file = "Aphex Twin/[1999] Aphex Twin - Windowlicker/01-02 - Aphex Twin - ∆Mᵢ⁻¹ = −∂ ∑ Dᵢ[n] [∑ Fⱼᵢ[n−1] + F extᵢ[n⁻¹]].mp3",
                .duration = 347.913,
                .last_modified = "2025-06-08T12:51:45Z",
                .added = "2025-05-25T22:06:52Z",
                .pos = 1,
                .song_id = 45,
                .format = .{
                    .sample_rate = 44100,
                    .bits = 16,
                    .channels = 2,
                },
                .tags = .{
                    .arena = song.tags.arena,
                    .artist = "Aphex Twin",
                    .artist_sort = "Aphex Twin",
                    .album_artist = "Aphex Twin",
                    .album = "Windowlicker",
                    .title = "∆Mᵢ⁻¹ = −∂ ∑ Dᵢ[n] [∑ Fⱼᵢ[n−1] + F extᵢ[n⁻¹]]",
                    .track = 2,
                    .disc = 1,
                    .genre = "Idm, Electronic, Ambient",
                    .date = "1999-03-22",
                    .original_date = "1999-03-22",
                    .composer = "Richard D. James",
                    .label = "Warp",
                    .mb_track_id = "109bba47-f0b9-42b3-91c4-48eb7e0ebc55",
                },
            },
            song,
        );
    }
}

pub const Subsystem = enum {
    /// Song database has been modified after an update
    database,
    /// Database update has started or finished
    update,
    /// A playlist has been modified, renamed, created or deleted
    playlist,
    /// Queue has been modified
    queue,
    /// Player has been started, stopped or seeked or tags of the currently playing song have changed
    /// (e.g. received from stream)
    player,
    /// Volume has been changed
    mixer,
    /// An audio output has been added, removed or modified (e.g. renamed, enabled or disabled)
    output,
    /// Options like repeat, random, crossfade, replay gain
    options,
    /// A partition was added, removed or changed
    partition,
    /// Sticker database has been modified
    sticker,
    /// A client has subscribed to or unsubscribed from a channel
    subscription,
    /// A message was received on a channel this client is subscribed to; this event is only emitted when the client's
    /// message queue is empty
    message,
    /// A neighbor was found or lost
    neighbor,
    /// Mount list has changed
    mount,
};

/// Blocks until there is a noteworthy change in one or more of MPD’s subsystems, returns an enum set of those that
/// changed.
pub fn idle(self: *Client) ResponseError!std.EnumSet(Subsystem) {
    try self.writer.writeAll("idle\n");
    try self.writer.flush();

    var set = std.EnumSet(Subsystem).initEmpty();

    while (try self.nextLine()) |kv|
        if (std.mem.eql(u8, kv.key, "changed")) {
            if (std.mem.eql(u8, kv.value, "database"))
                set.insert(.database)
            else if (std.mem.eql(u8, kv.value, "update"))
                set.insert(.update)
            else if (std.mem.eql(u8, kv.value, "stored_playlist"))
                set.insert(.playlist)
            else if (std.mem.eql(u8, kv.value, "playlist"))
                set.insert(.queue)
            else if (std.mem.eql(u8, kv.value, "player"))
                set.insert(.player)
            else if (std.mem.eql(u8, kv.value, "mixer"))
                set.insert(.mixer)
            else if (std.mem.eql(u8, kv.value, "output"))
                set.insert(.output)
            else if (std.mem.eql(u8, kv.value, "options"))
                set.insert(.options)
            else if (std.mem.eql(u8, kv.value, "partition"))
                set.insert(.partition)
            else if (std.mem.eql(u8, kv.value, "sticker"))
                set.insert(.sticker)
            else if (std.mem.eql(u8, kv.value, "subscription"))
                set.insert(.subscription)
            else if (std.mem.eql(u8, kv.value, "message"))
                set.insert(.message)
            else if (std.mem.eql(u8, kv.value, "neighbor"))
                set.insert(.neighbor)
            else if (std.mem.eql(u8, kv.value, "mount"))
                set.insert(.mount);
        };

    return set;
}

test idle {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\changed: playlist
        \\changed: player
        \\OK
    );

    const subsystems = try client.idle();

    try std.testing.expect(subsystems.eql(.initMany(&.{ .queue, .player })));
}

pub const SingleConsume = enum {
    off,
    on,
    oneshot,
};

pub const Status = struct {
    const State = enum { play, stop, pause };

    arena: std.heap.ArenaAllocator,

    partition: ?[]const u8 = null,
    /// Consider calling `getVolume` instead if you only need this
    volume: ?u8 = null,
    repeat: ?bool = null,
    random: ?bool = null,
    /// If repeat is also enabled, the current song is looped, otherwise playback stops after it.
    single: ?SingleConsume = null,
    consume: ?SingleConsume = null,
    queue_version: ?u32 = null,
    queue_length: ?i32 = null,
    state: ?State = null,
    /// Position of the current playing or stopped on song
    song_position: ?u32 = null,
    song_id: ?u32 = null,
    /// Position of the next song to be played
    next_song_position: ?u32 = null,
    next_song_id: ?u32 = null,
    /// Time elapsed in seconds
    elapsed: ?f32 = null,
    /// Song duration in seconds
    duration: ?f32 = null,
    /// Instantaneous bitrate in kbps
    bitrate: ?u32 = null,
    /// See https://mpd.readthedocs.io/en/latest/user.html#crossfading
    crossfade_seconds: ?u16 = null,
    mixramp_threshold_db: ?f32 = null,
    mixramp_delay_seconds: ?f32 = null,
    /// Format emitted by the decoder plugin during playback
    format: ?AudioFormat = null,
    /// Update job id
    update_id: ?u32 = null,
    last_loaded_playlist: ?u32 = null,

    pub inline fn deinit(self: *const Status) void {
        self.arena.deinit();
    }
};

/// Caller must call `Status.deinit` on the result to free strings
pub fn getStatus(self: *Client, allocator: std.mem.Allocator) ResponseError!Status {
    try self.writer.writeAll("status\n");
    try self.writer.flush();

    var res = Status{
        .arena = .init(allocator),
    };
    const alloc = res.arena.allocator();

    while (try self.nextLine()) |kv| {
        if (std.mem.eql(u8, kv.key, "partition"))
            res.partition = try alloc.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "volume"))
            res.volume = try std.fmt.parseUnsigned(u8, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "repeat"))
            res.repeat = std.mem.eql(u8, kv.value, "1")
        else if (std.mem.eql(u8, kv.key, "random"))
            res.random = std.mem.eql(u8, kv.value, "1")
        else if (std.mem.eql(u8, kv.key, "single"))
            res.single = if (std.mem.eql(u8, kv.value, "oneshot"))
                .oneshot
            else if (std.mem.eql(u8, kv.value, "1")) .on else .off
        else if (std.mem.eql(u8, kv.key, "consume"))
            res.consume = if (std.mem.eql(u8, kv.value, "oneshot"))
                .oneshot
            else if (std.mem.eql(u8, kv.value, "1")) .on else .off
        else if (std.mem.eql(u8, kv.key, "playlist"))
            res.queue_version = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "playlistlength"))
            res.queue_length = try std.fmt.parseInt(i32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "state")) {
            inline for (std.meta.fields(Status.State)) |s| {
                if (std.mem.eql(u8, kv.value, s.name)) {
                    res.state = @enumFromInt(s.value);
                    break;
                }
            }
        } else if (std.mem.eql(u8, kv.key, "song"))
            res.song_position = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "songid"))
            res.song_id = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "nextsong"))
            res.next_song_position = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "nextsongid"))
            res.next_song_id = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "elapsed"))
            res.elapsed = try std.fmt.parseFloat(f32, kv.value)
        else if (std.mem.eql(u8, kv.key, "duration"))
            res.duration = try std.fmt.parseFloat(f32, kv.value)
        else if (std.mem.eql(u8, kv.key, "bitrate"))
            res.bitrate = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "xfade"))
            res.crossfade_seconds = try std.fmt.parseUnsigned(u16, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "mixrampdb"))
            res.mixramp_threshold_db = try std.fmt.parseFloat(f32, kv.value)
        else if (std.mem.eql(u8, kv.key, "mixrampdelay"))
            res.mixramp_delay_seconds = try std.fmt.parseFloat(f32, kv.value)
        else if (std.mem.eql(u8, kv.key, "audio")) {
            res.format = try .parse(kv.value);
        } else if (std.mem.eql(u8, kv.key, "updating_db"))
            res.update_id = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "lastloadedplaylist"))
            res.last_loaded_playlist = try std.fmt.parseUnsigned(u32, kv.value, 10);
    }

    return res;
}

test getStatus {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\volume: 40
        \\repeat: 1
        \\random: 1
        \\single: 0
        \\consume: 0
        \\partition: default
        \\playlist: 26
        \\playlistlength: 11
        \\mixrampdb: 0
        \\state: play
        \\lastloadedplaylist:
        \\song: 1
        \\songid: 20
        \\time: 71:233
        \\elapsed: 70.667
        \\bitrate: 320
        \\duration: 232.989
        \\audio: 44100:16:2
        \\nextsong: 6
        \\nextsongid: 25
        \\OK
    );

    const status = try client.getStatus(std.testing.allocator);
    defer status.deinit();

    try std.testing.expectEqualDeep(
        Status{
            .arena = status.arena,
            .partition = "default",
            .volume = 40,
            .repeat = true,
            .random = true,
            .single = .off,
            .consume = .off,
            .queue_version = 26,
            .queue_length = 11,
            .state = .play,
            .song_position = 1,
            .song_id = 20,
            .next_song_position = 6,
            .next_song_id = 25,
            .elapsed = 70.667,
            .duration = 232.989,
            .bitrate = 320,
            .mixramp_threshold_db = 0,
            .format = .{
                .sample_rate = 44100,
                .bits = 16,
                .channels = 2,
            },
        },
        status,
    );
}

pub const Stats = struct {
    artists: ?u32 = null,
    albums: ?u32 = null,
    songs: ?u32 = null,
    /// Daemon uptime in seconds
    uptime: ?u64 = null,
    /// Last database update in Unix time
    last_db_update: ?u64 = null,
    /// Total amount of music played since daemon startup in seconds
    playtime: ?u64 = null,
    /// Total runtime of all songs in the database in seconds
    db_playtime: ?u64 = null,
};

pub fn getStats(self: *Client) ResponseError!Stats {
    try self.writer.writeAll("stats\n");
    try self.writer.flush();

    var res = Stats{};

    while (try self.nextLine()) |kv| {
        if (std.mem.eql(u8, kv.key, "artists"))
            res.artists = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "albums"))
            res.albums = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "songs"))
            res.songs = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "uptime"))
            res.uptime = try std.fmt.parseUnsigned(u64, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "db_update"))
            res.last_db_update = try std.fmt.parseUnsigned(u64, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "playtime"))
            res.playtime = try std.fmt.parseUnsigned(u64, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "db_playtime"))
            res.db_playtime = try std.fmt.parseUnsigned(u64, kv.value, 10);
    }

    return res;
}

test getStats {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\uptime: 15165
        \\playtime: 14701
        \\artists: 3182
        \\albums: 1306
        \\songs: 15061
        \\db_playtime: 3516788
        \\db_update: 1756037375
        \\OK
    );

    try std.testing.expectEqualDeep(
        Stats{
            .artists = 3182,
            .albums = 1306,
            .songs = 15061,
            .uptime = 15165,
            .last_db_update = 1756037375,
            .playtime = 14701,
            .db_playtime = 3516788,
        },
        try client.getStats(),
    );
}

pub fn setConsume(self: *Client, consume: SingleConsume) ResponseError!void {
    try self.writer.print("consume {s}\n", .{@tagName(consume)});
    try self.writer.flush();
    try self.checkResponse();
}

/// See https://mpd.readthedocs.io/en/latest/user.html#crossfading
pub fn setCrossfade(self: *Client, length_seconds: u16) ResponseError!void {
    try self.writer.print("crossfade {}\n", .{length_seconds});
    try self.writer.flush();
    try self.checkResponse();
}

pub fn setMixRampThreshold(self: *Client, threshold_db: f32) ResponseError!void {
    try self.writer.print("mixrampdb {d}\n", .{threshold_db});
    try self.writer.flush();
    try self.checkResponse();
}

pub fn setMixRampDelay(
    self: *Client,
    /// If null, disables MixRamp and falls back to crossfading
    delay_seconds: ?f32,
) ResponseError!void {
    if (delay_seconds) |d|
        try self.writer.print("mixrampdelay {d}\n", .{d})
    else
        try self.writer.writeAll("mixrampdelay nan\n");
    try self.writer.flush();
    try self.checkResponse();
}

/// Randomize playing order, not to be confused with `shuffle`
pub fn setRandom(self: *Client, random: bool) ResponseError!void {
    try self.writer.writeAll(if (random) "random 1\n" else "random 0\n");
    try self.writer.flush();
    try self.checkResponse();
}

/// If enabled, the queue is looped. If single mode is also enabled, the current song is looped.
pub fn setRepeat(self: *Client, repeat: bool) ResponseError!void {
    try self.writer.writeAll(if (repeat) "repeat 1\n" else "repeat 0\n");
    try self.writer.flush();
    try self.checkResponse();
}

/// Also available in `Status`
pub fn getVolume(self: *Client) ResponseError!u8 {
    try self.writer.writeAll("getvol\n");
    try self.writer.flush();

    while (try self.nextLine()) |kv|
        if (std.mem.eql(u8, kv.key, "volume"))
            return std.fmt.parseUnsigned(u8, kv.value, 10);

    return error.UnexpectedResponse;
}

test getVolume {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();
    fake.setResponse(
        \\volume: 45
        \\OK
    );
    try std.testing.expectEqual(45, try client.getVolume());
}

/// [0, 100]
pub fn setVolume(self: *Client, volume: u8) ResponseError!void {
    std.debug.assert(volume <= 100);

    try self.writer.print("setvol {}\n", .{volume});
    try self.writer.flush();
    try self.checkResponse();
}

/// [-100, 100]
pub fn setVolumeRelative(self: *Client, volume: i8) ResponseError!void {
    std.debug.assert(-100 <= volume and volume <= 100);

    try self.writer.print("volume {}\n", .{volume});
    try self.writer.flush();
    try self.checkResponse();
}

pub fn setSingle(self: *Client, single: SingleConsume) ResponseError!void {
    try self.writer.print("single {}\n", .{single});
    try self.writer.flush();
    try self.checkResponse();
}

pub const ReplayGainMode = enum {
    off,
    track,
    album,
    auto,
};

pub fn getReplayGain(self: *Client) ResponseError!ReplayGainMode {
    try self.writer.writeAll("replay_gain_status\n");
    try self.writer.flush();

    while (try self.nextLine()) |kv|
        if (std.mem.eql(u8, kv.key, "replay_gain_mode"))
            if (std.meta.stringToEnum(ReplayGainMode, kv.value)) |val| return val;

    return error.UnexpectedResponse;
}

/// Changing the mode during playback may take several seconds as new settings do not affect buffered data. This
/// function triggers the `Subsystem.options` idle event.
pub fn setReplayGain(self: *Client, mode: ReplayGainMode) ResponseError!void {
    try self.writer.print("replay_gain_mode {s}\n", .{@tagName(mode)});
    try self.writer.flush();
    try self.checkResponse();
}

pub fn previous(self: *Client) ResponseError!void {
    try self.writer.writeAll("previous\n");
    try self.writer.flush();
    try self.checkResponse();
}

pub fn next(self: *Client) ResponseError!void {
    try self.writer.writeAll("next\n");
    try self.writer.flush();
    try self.checkResponse();
}

pub fn pause(
    self: *Client,
    /// Pause if true, resume if false, toggle if null
    paused: ?bool,
) ResponseError!void {
    if (paused) |p|
        try self.writer.print("pause {s}\n", .{if (p) "1" else "0"})
    else
        try self.writer.writeAll("pause\n");
    try self.writer.flush();
    try self.checkResponse();
}

pub fn stop(self: *Client) ResponseError!void {
    try self.writer.writeAll("stop\n");
    try self.writer.flush();
    try self.checkResponse();
}

/// Play a song already in the queue
pub fn play(self: *Client, position: u32) ResponseError!void {
    try self.writer.print("play {}\n", .{position});
    try self.writer.flush();
    try self.checkResponse();
}

/// Play a song already in the queue
pub fn playId(self: *Client, id: u32) ResponseError!void {
    try self.writer.print("playid {}\n", .{id});
    try self.writer.flush();
    try self.checkResponse();
}

/// Seek to the specified absolute time in the song
pub fn seek(
    self: *Client,
    time_seconds: f32,
    /// Current song if null
    id: ?u32,
) ResponseError!void {
    std.debug.assert(time_seconds >= 0);

    if (id) |i|
        try self.writer.print("seekid {} {d}\n", .{ i, time_seconds })
    else
        try self.writer.print("seekcur {d}\n", .{time_seconds});
    try self.writer.flush();
    try self.checkResponse();
}

/// Seek to the specified absolute time in the song with the specified queue position
pub fn seekQueue(self: *Client, time_seconds: f32, position: u32) ResponseError!void {
    std.debug.assert(time_seconds >= 0);

    try self.writer.print("seek {} {d}\n", .{ position, time_seconds });
    try self.writer.flush();
    try self.checkResponse();
}

/// Seek to the specified time in the current song relative to the current playing position
pub fn seekRelative(self: *Client, time_seconds: f32) ResponseError!void {
    if (time_seconds >= 0)
        try self.writer.print("seekcur +{d}\n", .{time_seconds})
    else
        try self.writer.print("seekcur {d}\n", .{time_seconds});
    try self.writer.flush();
    try self.checkResponse();
}

pub const Position = union(enum) {
    absolute: u32,
    /// Number of songs between the current song and the new position (`0` inserts right before current song)
    before: u32,
    /// Number of songs between the current song and the new position (`0` inserts right after current song)
    after: u32,

    pub fn parse(position: []const u8) std.fmt.ParseIntError!Position {
        return if (std.mem.eql(u8, position, "before"))
            .{ .before = 0 }
        else if (std.mem.eql(u8, position, "after"))
            .{ .after = 0 }
        else if (std.mem.startsWith(u8, position, "-"))
            .{ .before = try std.fmt.parseUnsigned(u32, position[1..], 10) }
        else if (std.mem.startsWith(u8, position, "+"))
            .{ .after = try std.fmt.parseUnsigned(u32, position[1..], 10) }
        else
            .{ .absolute = try std.fmt.parseUnsigned(u32, position, 10) };
    }

    pub fn format(self: Position, writer: *std.Io.Writer) !void {
        switch (self) {
            .absolute => |p| try writer.print("{}", .{p}),
            .before => |p| try writer.print("-{}", .{p}),
            .after => |p| try writer.print("+{}", .{p}),
        }
    }
};

/// Add a song to the queue at the specified position. Returns the newly added song's ID.
pub fn add(
    self: *Client,
    /// Relative to the MPD library root or an absolute path to an audio file (if connected via a local Unix socket).
    // TODO: how do we determine how we're connected?
    path: []const u8,
    /// If null, insert at the end of the queue
    position: ?Position,
) ResponseError!u32 {
    try self.writer.writeAll("addid ");
    try self.writeQuoted(path);
    if (position) |pos|
        try self.writer.print(" {f}", .{pos});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    while (try self.nextLine()) |kv|
        if (std.mem.eql(u8, kv.key, "Id"))
            return try std.fmt.parseUnsigned(u8, kv.value, 10);

    return error.UnexpectedResponse;
}

pub fn clearQueue(self: *Client) ResponseError!void {
    try self.writer.writeAll("clear\n");
    try self.writer.flush();
    try self.checkResponse();
}

pub fn deleteFromQueuePos(self: *Client, position: u32) ResponseError!void {
    try self.writer.print("delete {}\n", .{position});
    try self.writer.flush();
    try self.checkResponse();
}

pub fn deleteFromQueueRange(self: *Client, range: Range) ResponseError!void {
    try self.writer.print("delete {f}\n", .{range});
    try self.writer.flush();
    try self.checkResponse();
}

pub fn deleteFromQueueId(self: *Client, id: u32) ResponseError!void {
    try self.writer.print("deleteid {}\n", .{id});
    try self.writer.flush();
    try self.checkResponse();
}

/// Move a song from the specified position to another in the queue
pub fn move(self: *Client, from: u32, to: Position) ResponseError!void {
    try self.writer.print("move {} {f}\n", .{ from, to });
    try self.writer.flush();
    try self.checkResponse();
}

/// Move songs with positions in the specified range (inclusive) to another in the queue
pub fn moveRange(self: *Client, from: Range, to: Position) ResponseError!void {
    try self.writer.print("move {f} {f}\n", .{ from, to });
    try self.writer.flush();
    try self.checkResponse();
}

/// Move a song with the specified ID to another position
pub fn moveId(self: *Client, id: u32, position: Position) ResponseError!void {
    try self.writer.print("moveid {} {f}\n", .{ id, position });
    try self.writer.flush();
    try self.checkResponse();
}

pub const Sort = struct {
    tag: tags.Tag,
    descending: bool = false,
};

pub const Range = struct {
    start: u32,
    end: ?u32,

    pub fn parse(range: []const u8) std.fmt.ParseIntError!Range {
        var it = std.mem.tokenizeScalar(u8, range, '-');
        const start = try std.fmt.parseUnsigned(u32, it.next().?, 10);
        return if (it.next()) |end|
            .{
                .start = start,
                .end = try std.fmt.parseUnsigned(u32, end, 10),
            }
        else
            .{
                .start = start,
                .end = null,
            };
    }

    pub fn format(self: Range, writer: *std.Io.Writer) !void {
        return if (self.end) |e|
            try writer.print("{}:{}", .{ self.start, e })
        else
            try writer.print("{}:", .{self.start});
    }
};

/// Query the queue for songs matching a filter string. Caller must call `Song.Iterator.deinit` on the result.
///
// TODO: filter string builder
pub fn queryQueue(
    self: *Client,
    allocator: std.mem.Allocator,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filter-syntax
    filter: []const u8,
    case_sensitive: bool,
    /// Optionally sort by a tag. `*_sort` variants will fall back to the regular tag.
    sort: ?Sort,
    /// Set to the start (inclusive) and end (exclusive) indices to optionally limit the output
    range: ?Range,
) ResponseError!Song.Iterator {
    try self.writer.writeAll(if (case_sensitive) "playlistfind " else "playlistsearch ");

    try self.writeQuoted(filter);

    if (range) |r| {
        if (sort) |s|
            try self.writer.print(" sort {f}", .{s.tag});

        try self.writer.print(" window {f}", .{r});
    } else if (sort) |s|
        try self.writer.print(" sort {f}", .{s.tag});

    try self.writer.writeByte('\n');
    try self.writer.flush();

    return .init(allocator, self);
}

pub fn getSongInQueueId(self: *Client, allocator: std.mem.Allocator, id: u32) ResponseError!Song {
    try self.writer.print("playlistid {}\n", .{id});
    try self.writer.flush();

    return try Song.parse(self, allocator);
}

pub fn getSongInQueuePos(self: *Client, allocator: std.mem.Allocator, position: u32) ResponseError!Song {
    try self.writer.print("playlistinfo {}\n", .{position});
    try self.writer.flush();

    return try Song.parse(self, allocator);
}

/// Caller must call `Song.Iterator.deinit` on the result
pub fn getSongsInQueueRange(self: *Client, allocator: std.mem.Allocator, range: Range) ResponseError!Song.Iterator {
    try self.writer.print("playlistinfo {f}\n", .{range});
    try self.writer.flush();

    return .init(allocator, self);
}

/// Caller must call `Song.Iterator.deinit` on the result
pub fn getQueue(self: *Client, allocator: std.mem.Allocator) ResponseError!Song.Iterator {
    try self.writer.writeAll("playlistinfo\n");
    try self.writer.flush();

    return .init(allocator, self);
}

/// Get changed songs in the queue since `previous_version`. Use the `queue_length` field in `Status` to detect songs
/// that were deleted.
///
/// Caller must call `Song.Iterator.deinit` on the result.
///
/// Use `queueChangesPosId` if you only need position and ID changes.
pub fn getQueueChanges(
    self: *Client,
    allocator: std.mem.Allocator,
    previous_version: u32,
    /// Optionally limit the output
    range: ?Range,
) ResponseError!Song.Iterator {
    if (range) |r| {
        try self.writer.print("plchanges {} {f}\n", .{ previous_version, r });
    } else try self.writer.print("plchanges {}\n", .{previous_version});
    try self.writer.flush();

    return .init(allocator, self);
}

pub const PosId = struct {
    position: u32,
    id: u32,

    pub const Iterator = struct {
        client: *Client,
        last_position: ?u32 = null,
        last_kv: ?zmpd.KV,

        pub fn init(client: *Client) ResponseError!Iterator {
            return .{
                .client = client,
                .last_kv = try client.nextLine(),
            };
        }

        pub fn next(self: *Iterator) ResponseError!?PosId {
            if (self.last_kv == null) return null;

            var current = PosId{
                .id = 0,
                .position = self.last_position orelse 0,
            };

            while (self.last_kv) |kv| {
                if (std.mem.eql(u8, kv.key, "cpos")) {
                    if (self.last_position) |_| {
                        self.last_position = try std.fmt.parseUnsigned(u32, kv.value, 10);
                        self.last_kv = try self.client.nextLine();
                        return current;
                    } else {
                        current.position = try std.fmt.parseUnsigned(u32, kv.value, 10);
                        self.last_position = current.position;
                    }
                } else if (std.mem.eql(u8, kv.key, "Id"))
                    current.id = try std.fmt.parseUnsigned(u32, kv.value, 10);

                self.last_kv = try self.client.nextLine();
            }

            return current;
        }
    };
};

/// Get positions and IDs of changed songs in the queue since `previous_version`. Use the `queue_length` field in
/// `Status` to detect songs that were deleted.
///
/// This is more efficient than `queueChanges`.
pub fn getQueueChangesPosId(self: *Client, previous_version: u32, range: ?Range) ResponseError!PosId.Iterator {
    if (range) |r| {
        try self.writer.print("plchangesposid {} {f}\n", .{ previous_version, r });
    } else try self.writer.print("plchangesposid {}\n", .{previous_version});
    try self.writer.flush();

    return try .init(self);
}

test getQueueChangesPosId {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\cpos: 0
        \\Id: 120
        \\cpos: 1
        \\Id: 121
        \\cpos: 2
        \\Id: 122
        \\cpos: 3
        \\Id: 123
        \\OK
    );

    var it = try client.getQueueChangesPosId(0, null);
    try std.testing.expectEqualDeep(PosId{
        .position = 0,
        .id = 120,
    }, (try it.next()).?);
    try std.testing.expectEqualDeep(PosId{
        .position = 1,
        .id = 121,
    }, (try it.next()).?);
    try std.testing.expectEqualDeep(PosId{
        .position = 2,
        .id = 122,
    }, (try it.next()).?);
    try std.testing.expectEqualDeep(PosId{
        .position = 3,
        .id = 123,
    }, (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}

/// A higher priority means the song will be played first when random mode is enabled. Newly added songs have a default
/// priority of 0.
pub fn setPriority(self: *Client, position: u32, priority: u8) ResponseError!void {
    try self.writer.print("prio {} {}\n", .{ priority, position });
    try self.writer.flush();
    try self.checkResponse();
}

/// A higher priority means the song will be played first when random mode is enabled. Newly added songs have a default
/// priority of 0.
pub fn setPriorityRange(self: *Client, range: Range, priority: u8) ResponseError!void {
    try self.writer.print("prio {} {f}\n", .{ priority, range });
    try self.writer.flush();
    try self.checkResponse();
}

/// A higher priority means the song will be played first when random mode is enabled. Newly added songs have a default
/// priority of 0.
pub fn setPriorityId(self: *Client, id: u32, priority: u8) ResponseError!void {
    try self.writer.print("prioid {} {}\n", .{ priority, id });
    try self.writer.flush();
    try self.checkResponse();
}

/// Specify the portion of a song that shall be played. Does not work for the currently playing song.
pub fn setSongRange(
    self: *Client,
    id: u32,
    /// If null, the song will be played in full
    range_seconds: ?FloatRange,
) ResponseError!void {
    if (range_seconds) |r|
        try self.writer.print("rangeid {} {f}\n", .{ id, r })
    else
        try self.writer.print("rangeid {} :\n", .{id});
    try self.writer.flush();

    try self.checkResponse();
}

/// Shuffle the queue. Not to be confused with random mode.
pub fn shuffle(
    self: *Client,
    /// Optionally shuffle a range of positions
    range: ?Range,
) ResponseError!void {
    if (range) |r|
        try self.writer.print("shuffle {f}\n", .{r})
    else
        try self.writer.writeAll("shuffle\n");
    try self.writer.flush();
    try self.checkResponse();
}

pub fn swapInQueuePos(self: *Client, position_a: u32, position_b: u32) ResponseError!void {
    try self.writer.print("swap {} {}\n", .{ position_a, position_b });
    try self.writer.flush();
    try self.checkResponse();
}

pub fn swapInQueueId(self: *Client, id_a: u32, id_b: u32) ResponseError!void {
    try self.writer.print("swapid {} {}\n", .{ id_a, id_b });
    try self.writer.flush();
    try self.checkResponse();
}

/// Only works for remote songs. The changes may be overwritten by the server and reverted when the song is removed from
/// the queue.
pub fn addTag(self: *Client, id: u32, tag: tags.Tag, value: []const u8) ResponseError!void {
    try self.writer.print("addtagid {} {f} ", .{ id, tag });
    try self.writeQuoted(value);
    try self.writer.writeByte('\n');
    try self.writer.flush();
    try self.checkResponse();
}

/// Remove a tag from the specified song. The changes may be reverted by the server. Only works for remote songs.
pub fn clearTag(
    self: *Client,
    id: u32,
    /// Remove all tags if null
    tag: ?tags.Tag,
) ResponseError!void {
    if (tag) |t|
        try self.writer.print("cleartagid {} {f}\n", .{ id, t })
    else
        try self.writer.print("cleartagid {}\n", .{id});
    try self.writer.flush();

    try self.checkResponse();
}

pub const FileIterator = struct {
    allocator: std.mem.Allocator,
    client: *Client,

    /// Caller owns each result
    pub fn next(self: *FileIterator) ResponseError!?[]const u8 {
        while (try self.client.nextLine()) |kv| {
            if (std.mem.eql(u8, kv.key, "file"))
                return try self.allocator.dupe(u8, kv.value);
        }
        return null;
    }
};

/// List songs paths in the specified playlist. Caller must call `PlaylistSongs.deinit` on the result.
pub fn getPlaylistSongs(
    self: *Client,
    allocator: std.mem.Allocator,
    name: []const u8,
    /// Optionally limit the output
    range: ?Range,
) ResponseError!FileIterator {
    try self.writer.writeAll("listplaylist ");
    try self.writeQuoted(name);
    if (range) |r|
        try self.writer.print(" {f}", .{r});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return .{
        .allocator = allocator,
        .client = self,
    };
}

test getPlaylistSongs {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\file: Car Bomb/[2012] Car Bomb - w^w^^w^w/01-01 - Car Bomb - The Sentinel.mp3
        \\file: Car Bomb/[2012] Car Bomb - w^w^^w^w/01-02 - Car Bomb - Auto-named.mp3
        \\file: Car Bomb/[2012] Car Bomb - w^w^^w^w/01-03 - Car Bomb - Finish It.mp3
        \\OK
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var it = try client.getPlaylistSongs(arena.allocator(), "hjkuvxyciuydfiuydsf", null);

    try std.testing.expectEqualStrings("Car Bomb/[2012] Car Bomb - w^w^^w^w/01-01 - Car Bomb - The Sentinel.mp3", (try it.next()).?);
    try std.testing.expectEqualStrings("Car Bomb/[2012] Car Bomb - w^w^^w^w/01-02 - Car Bomb - Auto-named.mp3", (try it.next()).?);
    try std.testing.expectEqualStrings("Car Bomb/[2012] Car Bomb - w^w^^w^w/01-03 - Car Bomb - Finish It.mp3", (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}

/// List songs with metadata in the specified playlist. Caller must call `Song.Iterator.deinit` on the result.
pub fn getPlaylistSongsMetadata(
    self: *Client,
    allocator: std.mem.Allocator,
    playlist: []const u8,
    /// Optionally limit the output
    range: ?Range,
) ResponseError!Song.Iterator {
    try self.writer.writeAll("listplaylistinfo ");
    try self.writeQuoted(playlist);
    if (range) |r|
        try self.writer.print(" {f}", .{r});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return .init(allocator, self);
}

/// Search a playlist for songs matching the filter. Caller must call `Song.Iterator.deinit` on the result.
pub fn queryPlaylist(
    self: *Client,
    allocator: std.mem.Allocator,
    playlist: []const u8,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filter-syntax
    filter: []const u8,
    /// Optionally limit the output
    range: ?Range,
) ResponseError!Song.Iterator {
    try self.writer.writeAll("searchplaylist ");
    try self.writeQuoted(playlist);
    try self.writer.writeByte(' ');
    try self.writeQuoted(filter);
    if (range) |r|
        try self.writer.print(" {f}", .{r});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return .init(allocator, self);
}

pub const Playlist = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    /// ISO-8601 date
    last_modified: []const u8,

    pub fn deinit(self: *const Playlist) void {
        self.arena.deinit();
    }

    pub const Iterator = struct {
        allocator: std.mem.Allocator,
        client: *Client,
        // current: Playlist = undefined,
        last_name: ?[]const u8 = null,
        last_kv: ?zmpd.KV,

        pub fn init(allocator: std.mem.Allocator, client: *Client) ResponseError!Iterator {
            return .{
                .allocator = allocator,
                .client = client,
                .last_kv = try client.nextLine(),
            };
        }

        /// Caller must call `Playlist.deinit` on each result
        pub fn next(self: *Iterator) ResponseError!?Playlist {
            if (self.last_kv == null) return null;

            var current = Playlist{
                .arena = .init(self.allocator),
                .name = "",
                .last_modified = "",
            };
            const allocator = current.arena.allocator();

            if (self.last_name) |last_name|
                current.name = try allocator.dupe(u8, last_name);

            while (self.last_kv) |kv| {
                if (std.mem.eql(u8, kv.key, "playlist")) {
                    if (self.last_name) |last_name| {
                        self.allocator.free(last_name);
                        self.last_name = try self.allocator.dupe(u8, kv.value);
                        self.last_kv = try self.client.nextLine();
                        return current;
                    } else {
                        self.last_name = try self.allocator.dupe(u8, kv.value);
                        current.name = try allocator.dupe(u8, kv.value);
                    }
                } else if (std.mem.eql(u8, kv.key, "Last-Modified"))
                    current.last_modified = try allocator.dupe(u8, kv.value);
                self.last_kv = try self.client.nextLine();
            }

            return current;
        }

        pub inline fn deinit(self: *const Iterator) void {
            if (self.last_name) |last_name|
                self.allocator.free(last_name);
        }
    };
};

/// Get a list of playlists in MPD's playlist directory. Caller must call `Playlist.Iterator.deinit` on the result.
pub fn getPlaylists(self: *Client, allocator: std.mem.Allocator) ResponseError!Playlist.Iterator {
    try self.writer.writeAll("listplaylists\n");
    try self.writer.flush();

    return try .init(allocator, self);
}

test getPlaylists {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\playlist: gsdfhjkdhjksf
        \\Last-Modified: 2025-07-31T19:26:07Z
        \\playlist: iuydfyiufdsfiuydsfiu
        \\Last-Modified: 2025-08-03T19:04:07Z
        \\playlist: hjkuvxyciuydfiuydsf
        \\Last-Modified: 2025-08-03T19:23:10Z
        \\OK
    );

    var it = try client.getPlaylists(std.testing.allocator);
    defer it.deinit();

    {
        var playlist = (try it.next()).?;
        defer playlist.deinit();
        try std.testing.expectEqualDeep(Playlist{
            .arena = playlist.arena,
            .name = "gsdfhjkdhjksf",
            .last_modified = "2025-07-31T19:26:07Z",
        }, playlist);
    }
    {
        var playlist = (try it.next()).?;
        defer playlist.deinit();
        try std.testing.expectEqualDeep(Playlist{
            .arena = playlist.arena,
            .name = "iuydfyiufdsfiuydsfiu",
            .last_modified = "2025-08-03T19:04:07Z",
        }, playlist);
    }
    {
        var playlist = (try it.next()).?;
        defer playlist.deinit();
        try std.testing.expectEqualDeep(Playlist{
            .arena = playlist.arena,
            .name = "hjkuvxyciuydfiuydsf",
            .last_modified = "2025-08-03T19:23:10Z",
        }, playlist);
    }
    try std.testing.expectEqual(null, try it.next());
}

/// Load a playlist into the queue
pub fn loadPlaylist(
    self: *Client,
    playlist: []const u8,
    /// Optionally load only part of the playlist
    range: ?Range,
    /// If null, insert at the end of the queue
    position: ?Position,
) ResponseError!void {
    try self.writer.writeAll("load ");
    try self.writeQuoted(playlist);
    if (range) |r|
        try self.writer.print(" {f}", .{r});
    if (position) |pos|
        try self.writer.print(" {f}", .{pos});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    try self.checkResponse();
}

/// Add the specified path relative to MPD's library root to a playlist.
///
/// If a playlist with the specified name does not exist, it will be created, failing if `position` is not null or 0.
pub fn addToPlaylist(
    self: *Client,
    playlist: []const u8,
    song: []const u8,
    /// If null, insert at the end of the playlist
    position: ?u32,
) ResponseError!void {
    try self.writer.writeAll("playlistadd ");
    try self.writeQuoted(playlist);
    try self.writer.writeByte(' ');
    try self.writeQuoted(song);
    if (position) |pos|
        try self.writer.print(" {}", .{pos});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    try self.checkResponse();
}

/// Remove all songs from a playlist
pub fn clearPlaylist(self: *Client, playlist: []const u8) ResponseError!void {
    try self.writer.writeAll("playlistclear ");
    try self.writeQuoted(playlist);
    try self.writer.writeByte('\n');
    try self.writer.flush();

    try self.checkResponse();
}

pub fn deleteFromPlaylist(self: *Client, playlist: []const u8, position: u32) ResponseError!void {
    try self.writer.writeAll("playlistdelete ");
    try self.writeQuoted(playlist);
    try self.writer.print(" {}\n", .{position});
    try self.writer.flush();

    try self.checkResponse();
}

pub const PlaylistLength = struct {
    songs: u32,
    playtime_seconds: u32,
};

pub fn getPlaylistLength(self: *Client, playlist: []const u8) ResponseError!PlaylistLength {
    try self.writer.writeAll("playlistlength ");
    try self.writeQuoted(playlist);
    try self.writer.writeByte('\n');
    try self.writer.flush();

    var res = std.mem.zeroInit(PlaylistLength, .{});

    while (try self.nextLine()) |kv| {
        if (std.mem.eql(u8, kv.key, "songs"))
            res.songs = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "playtime"))
            res.playtime_seconds = try std.fmt.parseUnsigned(u32, kv.value, 10);
    }

    return res;
}

test getPlaylistLength {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\songs: 12
        \\playtime: 3003
        \\OK
    );

    try std.testing.expectEqualDeep(PlaylistLength{
        .songs = 12,
        .playtime_seconds = 3003,
    }, try client.getPlaylistLength("hjkuvxyciuydfiuydsf"));
}

pub fn renamePlaylist(self: *Client, old: []const u8, new: []const u8) ResponseError!void {
    try self.writer.writeAll("rename ");
    try self.writeQuoted(old);
    try self.writer.writeByte(' ');
    try self.writeQuoted(new);
    try self.writer.writeByte('\n');
    try self.writer.flush();

    try self.checkResponse();
}

pub fn removePlaylist(self: *Client, playlist: []const u8) ResponseError!void {
    try self.writer.writeAll("rm ");
    try self.writeQuoted(playlist);
    try self.writer.writeByte('\n');
    try self.writer.flush();

    try self.checkResponse();
}

pub const SavePlaylistMode = enum { create, append, replace };

/// Save the current queue to a playlist
pub fn savePlaylist(
    self: *Client,
    name: []const u8,
    /// `SavePlaylistMode.create` is the default if null
    mode: ?SavePlaylistMode,
) ResponseError!void {
    try self.writer.writeAll("save ");
    try self.writeQuoted(name);
    if (mode) |m| {
        try self.writer.writeByte(' ');
        try self.writer.writeAll(@tagName(m));
    }
    try self.writer.writeByte('\n');
    try self.writer.flush();

    try self.checkResponse();
}

/// Get the current song's album art as raw bytes.
pub fn getAlbumArt(
    self: *Client,
    /// If you just want a slice of bytes, consider `std.Io.Writer.Allocating`
    writer: *std.Io.Writer,
    path: []const u8,
    opts: struct {
        /// Whether to read binary data from the file's tag instead of looking for files named `cover.png`, `cover.jpg`
        /// or `cover.webp`
        from_tag: bool = false,
        start_offset: usize = 0,
    },
) ResponseError!usize {
    var written: usize = opts.start_offset;
    var size: u32 = 1;
    while (written < size) {
        try self.writer.writeAll(if (opts.from_tag) "readpicture" else "albumart ");
        try self.writeQuoted(path);
        try self.writer.print(" {}\n", .{written});
        try self.writer.flush();

        var binary: ?u32 = null;

        blk: while (try self.nextLine()) |kv| {
            if (std.mem.eql(u8, kv.key, "size"))
                size = try std.fmt.parseUnsigned(u32, kv.value, 10)
            else if (std.mem.eql(u8, kv.key, "binary")) {
                binary = try std.fmt.parseUnsigned(u32, kv.value, 10);
                break :blk;
            }
        }

        const n = (binary orelse return error.UnexpectedResponse);
        try self.reader.streamExact(writer, n);
        try self.checkResponse();
        written += n;
    }
    std.debug.assert(written == size);
    return written;
}

pub const Count = struct {
    songs: ?u32 = null,
    length_seconds: ?u64 = null,

    pub fn parse(client: *Client) ResponseError!Count {
        var res = Count{};

        while (try client.nextLine()) |kv| {
            if (std.mem.eql(u8, kv.key, "songs"))
                res.songs = try std.fmt.parseUnsigned(u32, kv.value, 10)
            else if (std.mem.eql(u8, kv.key, "playtime"))
                res.length_seconds = try std.fmt.parseUnsigned(u64, kv.value, 10);
        }

        return res;
    }
};

/// Count the number of songs matching a filter string and their total playtime
///
/// See `countGroup`
pub fn count(
    self: *Client,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filter-syntax
    filter: []const u8,
) ResponseError!Count {
    try self.writer.writeAll("count ");
    try self.writeQuoted(filter);
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return try .parse(self);
}

test count {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\songs: 27
        \\playtime: 8242
        \\OK
    );

    try std.testing.expectEqualDeep(
        Count{
            .songs = 27,
            .length_seconds = 8242,
        },
        try client.count("(Artist == 'Untold')"),
    );
}

pub const CountGroup = struct {
    allocator: std.mem.Allocator,
    value: []const u8,
    songs: ?u32 = null,
    length_seconds: ?u64 = null,

    pub inline fn deinit(self: *const CountGroup) void {
        self.allocator.free(self.value);
    }

    pub const Iterator = struct {
        allocator: std.mem.Allocator,
        client: *Client,
        tag_string: []const u8,
        last_kv: ?zmpd.KV,
        last_value: ?[]const u8 = null,

        pub fn init(allocator: std.mem.Allocator, client: *Client, tag: tags.Tag) ResponseError!Iterator {
            return .{
                .allocator = allocator,
                .client = client,
                .tag_string = tag.string(),
                .last_kv = try client.nextLine(),
            };
        }

        /// Caller must call `CountGroup.deinit` on each result
        pub fn next(self: *Iterator) ResponseError!?CountGroup {
            if (self.last_kv == null) return null;

            var current = CountGroup{
                .allocator = self.allocator,
                .value = "",
            };

            if (self.last_value) |last_value|
                current.value = try self.allocator.dupe(u8, last_value);

            while (self.last_kv) |kv| {
                if (std.mem.eql(u8, kv.key, self.tag_string)) {
                    if (self.last_value) |last_value| {
                        self.allocator.free(last_value);
                        self.last_value = try self.allocator.dupe(u8, kv.value);
                        self.last_kv = try self.client.nextLine();
                        return current;
                    } else {
                        self.last_value = try self.allocator.dupe(u8, kv.value);
                        current.value = try self.allocator.dupe(u8, kv.value);
                    }
                } else if (std.mem.eql(u8, kv.key, "songs"))
                    current.songs = try std.fmt.parseUnsigned(u32, kv.value, 10)
                else if (std.mem.eql(u8, kv.key, "playtime"))
                    current.length_seconds = try std.fmt.parseUnsigned(u64, kv.value, 10);

                self.last_kv = try self.client.nextLine();
            }

            return current;
        }

        pub inline fn deinit(self: *const Iterator) void {
            if (self.last_value) |last_value|
                self.allocator.free(last_value);
        }
    };
};

/// Count the number of songs and their total playtime grouped by a tag. Caller must call `CountGroup.Iterator.deinit`
/// on the result.
///
/// See `count`
pub fn countGroup(
    self: *Client,
    allocator: std.mem.Allocator,
    tag: tags.Tag,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filter-syntax
    filter: ?[]const u8,
) ResponseError!CountGroup.Iterator {
    try self.writer.writeAll("count ");
    if (filter) |f| {
        try self.writeQuoted(f);
        try self.writer.writeByte(' ');
    }
    try self.writer.print("group {f}\n", .{tag});
    try self.writer.flush();

    return try .init(allocator, self, tag);
}

test countGroup {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\Album: Horse Rotorvator
        \\songs: 12
        \\playtime: 2955
        \\Album: How to Destroy Angels
        \\songs: 2
        \\playtime: 2363
        \\Album: Scatology
        \\songs: 13
        \\playtime: 3295
        \\OK
    );

    var it = try client.countGroup(std.testing.allocator, .album, "(Artist == 'Coil')");
    defer it.deinit();

    {
        const c = (try it.next()).?;
        defer c.deinit();
        try std.testing.expectEqualDeep(
            CountGroup{
                .allocator = std.testing.allocator,
                .value = "Horse Rotorvator",
                .songs = 12,
                .length_seconds = 2955,
            },
            c,
        );
    }
    {
        const c = (try it.next()).?;
        defer c.deinit();
        try std.testing.expectEqualDeep(
            CountGroup{
                .allocator = std.testing.allocator,
                .value = "How to Destroy Angels",
                .songs = 2,
                .length_seconds = 2363,
            },
            c,
        );
    }
    {
        const c = (try it.next()).?;
        defer c.deinit();
        try std.testing.expectEqualDeep(
            CountGroup{
                .allocator = std.testing.allocator,
                .value = "Scatology",
                .songs = 13,
                .length_seconds = 3295,
            },
            c,
        );
    }
    try std.testing.expectEqual(null, try it.next());
}

/// Calculate the song's audio fingerprint. Only works if MPD was compiled with libchromaprint, returns
/// `ProtocolError.Unknown` otherwise.
///
/// Caller owns the returned string
pub fn getFingerprint(self: *Client, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    try self.writer.writeAll("getfingerprint ");
    try self.writeQuoted(path);
    try self.writer.flush();

    while (try self.nextLine()) |kv|
        if (std.mem.eql(u8, kv.key, "chromaprint"))
            return try allocator.dupe(u8, kv.value);

    return error.UnexpectedResponse;
}

/// Search the database for songs matching a filter string. Caller must call `Song.Iterator.deinit` on the result.
pub fn queryDatabase(
    self: *Client,
    allocator: std.mem.Allocator,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filter-syntax
    filter: []const u8,
    /// Optionally sort by a tag. `*_sort` variants will fall back to the regular tag.
    sort: ?tags.Tag,
    /// Optionally limit the output
    range: ?Range,
) ResponseError!Song.Iterator {
    try self.writer.writeAll("find ");
    try self.writeQuoted(filter);
    if (sort) |tag|
        try self.writer.print(" sort {f}", .{tag});
    if (range) |r|
        try self.writer.print(" window {f}", .{r});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return .init(allocator, self);
}

/// Search the database for songs matching a filter string and add them to the queue
pub fn queryDatabaseAdd(
    self: *Client,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filter-syntax
    filter: []const u8,
    /// Optionally sort by a tag. `*_sort` variants will fall back to the regular tag.
    sort: ?tags.Tag,
    /// Optionally limit the output
    range: ?Range,
    /// If null, insert at the end of the queue
    position: ?Position,
) ResponseError!void {
    try self.writer.writeAll("findadd ");
    try self.writeQuoted(filter);
    if (sort) |tag|
        try self.writer.print(" sort {f}", .{tag});
    if (range) |r|
        try self.writer.print(" window {f}", .{r});
    if (position) |pos|
        try self.writer.print(" position {f}", .{pos});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    try self.checkResponse();
}

/// Search the database for songs matching a filter string and count their playtime
pub fn queryDatabaseCount(
    self: *Client,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filter-syntax
    filter: []const u8,
) ResponseError!Count {
    try self.writer.writeAll("searchcount ");
    try self.writeQuoted(filter);
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return .parse(self);
}

pub const UniqueIterator = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    tag_string: []const u8,

    pub fn init(allocator: std.mem.Allocator, client: *Client, tag: tags.Tag) UniqueIterator {
        return .{
            .allocator = allocator,
            .client = client,
            .tag_string = tag.string(),
        };
    }

    /// Caller owns the returned string
    pub fn next(self: *UniqueIterator) ResponseError!?[]const u8 {
        while (try self.client.nextLine()) |kv|
            if (std.mem.eql(u8, kv.key, self.tag_string))
                return try self.allocator.dupe(u8, kv.value);
        return null;
    }
};

/// List unique values of a specified tag.
///
/// See `listUniqueGroup`
pub fn getUnique(
    self: *Client,
    allocator: std.mem.Allocator,
    tag: tags.Tag,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filters
    filter: ?[]const u8,
) ResponseError!UniqueIterator {
    const tag_string = tag.string();
    try self.writer.print("list {s}", .{tag_string});
    if (filter) |f|
        try self.writer.print(" {s}", .{f});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return .init(allocator, self, tag);
}

test getUnique {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\Album: Amongst the Catacombs of Nephren-Ka
        \\Album: Calculating Infinity
        \\Album: Caustic Window LP
        \\Album: Centralia
        \\OK
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var it = try client.getUnique(arena.allocator(), .album, "(added-since '2025-08')");

    try std.testing.expectEqualStrings("Amongst the Catacombs of Nephren-Ka", (try it.next()).?);
    try std.testing.expectEqualStrings("Calculating Infinity", (try it.next()).?);
    try std.testing.expectEqualStrings("Caustic Window LP", (try it.next()).?);
    try std.testing.expectEqualStrings("Centralia", (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}

pub const UniqueGroup = union {
    group: []const u8,
    entry: []const u8,

    pub const Iterator = struct {
        allocator: std.mem.Allocator,
        client: *Client,
        tag_string: []const u8,
        group_string: []const u8,

        /// Caller owns the returned string
        pub fn next(self: *Iterator) ResponseError!?UniqueGroup {
            while (try self.client.nextLine()) |kv| {
                if (std.mem.eql(u8, kv.key, self.group_string))
                    return .{ .group = try self.allocator.dupe(u8, kv.value) }
                else if (std.mem.eql(u8, kv.key, self.tag_string))
                    return .{ .entry = try self.allocator.dupe(u8, kv.value) };
            }
            return null;
        }
    };
};

/// List unique values of a specified tag, grouped by a different tag.
///
/// See `listUnique`
pub fn getUniqueGroup(
    self: *Client,
    allocator: std.mem.Allocator,
    tag: tags.Tag,
    group: tags.Tag,
    /// See https://mpd.readthedocs.io/en/latest/protocol.html#filters
    filter: ?[]const u8,
    /// Optionally limit the output
    range: ?Range,
) ResponseError!UniqueGroup.Iterator {
    std.debug.assert(tag != group);

    const tag_string = tag.string();
    const group_string = group.string();
    try self.writer.print("list {s}", .{tag_string});
    if (filter) |f|
        try self.writer.print(" {s}", .{f});
    try self.writer.print(" {s}", .{group_string});
    if (range) |r|
        try self.writer.print(" window {f}", .{r});
    try self.writer.writeByte('\n');
    try self.writer.flush();

    return UniqueGroup.Iterator{
        .allocator = allocator,
        .client = self,
        .group_string = group.string(),
        .tag_string = tag.string(),
    };
}

test getUniqueGroup {
    var fake = try FakeClient.init(std.testing.allocator);
    defer fake.deinit();
    var client = try fake.client();

    fake.setResponse(
        \\AlbumArtist: Car Bomb
        \\Album: Centralia
        \\Album: Tiles Whisper Dreams
        \\AlbumArtist: Caustic Window
        \\Album: Caustic Window LP
        \\AlbumArtist: Coil
        \\Album: Horse Rotorvator
        \\OK
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var it = try client.getUniqueGroup(
        arena.allocator(),
        .album,
        .album_artist,
        "(added-since '2025-08')",
        null,
    );

    try std.testing.expectEqualStrings("Car Bomb", (try it.next()).?.group);
    try std.testing.expectEqualStrings("Centralia", (try it.next()).?.entry);
    try std.testing.expectEqualStrings("Tiles Whisper Dreams", (try it.next()).?.entry);
    try std.testing.expectEqualStrings("Caustic Window", (try it.next()).?.group);
    try std.testing.expectEqualStrings("Caustic Window LP", (try it.next()).?.entry);
    try std.testing.expectEqualStrings("Coil", (try it.next()).?.group);
    try std.testing.expectEqualStrings("Horse Rotorvator", (try it.next()).?.entry);
}

/// Update the database with added, removed and modified files. Returns the update job (see `Status.update_id`).
pub fn updateDatabase(
    self: *Client,
    /// Specify a directory or file to update. If null, update the entire database.
    path: ?[]const u8,
    scan_unmodified: bool,
) ResponseError!u32 {
    try self.writer.writeAll(if (scan_unmodified) "rescan" else "update");
    if (path) |p| {
        try self.writer.writeByte(' ');
        try self.writeQuoted(p);
    }
    try self.writer.writeByte('\n');
    try self.writer.flush();

    while (try self.nextLine()) |kv|
        if (std.mem.eql(u8, kv.key, "updating_db"))
            return try std.fmt.parseUnsigned(u32, kv.value, 10);

    return error.UnexpectedResponse;
}

comptime {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(tags);
}
