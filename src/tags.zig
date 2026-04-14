const std = @import("std");
const zmpd = @import("zmpd.zig");

pub const Tag = enum {
    artist,
    artist_sort,
    album_artist,
    album_artist_sort,
    album,
    album_sort,
    title,
    title_sort,
    track,
    disc,
    name,
    genre,
    date,
    original_date,
    composer,
    composer_sort,
    performer,
    comment,
    label,
    grouping,
    work,
    conductor,
    ensemble,
    movement,
    movement_number,
    show_movement,
    location,
    mood,

    mb_artist_id,
    mb_album_artist_id,
    mb_album_id,
    mb_track_id,
    mb_release_track_id,
    mb_release_group_id,
    mb_work_id,

    pub fn string(self: Tag) []const u8 {
        const fields = @typeInfo(MpdTags).@"enum".fields;
        const map = std.StaticStringMap(MpdTags).initComptime(blk: {
            var kvs: [fields.len]struct { []const u8, MpdTags } = undefined;
            for (fields, 0..) |field, i| {
                kvs[i] = .{ @tagName(@field(mpd_map, field.name)), @enumFromInt(field.value) };
            }
            break :blk kvs;
        });
        return @tagName(map.get(@tagName(self)).?);
    }

    pub fn format(self: Tag, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.string());
    }
};

/// tag names as reported by MPD:
/// https://github.com/MusicPlayerDaemon/libmpdclient/blob/cc2f3e0199520c93ca28c5deb4520c938b8cdebb/src/tag.c#L10-L51
const mpd_map = .{
    .Artist = .artist,
    .ArtistSort = .artist_sort,
    .AlbumArtist = .album_artist,
    .AlbumArtistSort = .album_artist_sort,
    .Album = .album,
    .AlbumSort = .album_sort,
    .Title = .title,
    .TitleSort = .title_sort,
    .Track = .track,
    .Disc = .disc,
    .Name = .name,
    .Genre = .genre,
    .Date = .date,
    .OriginalDate = .original_date,
    .Composer = .composer,
    .ComposerSort = .composer_sort,
    .Performer = .performer,
    .Comment = .comment,
    .Label = .label,
    .Grouping = .grouping,
    .Work = .work,
    .Conductor = .conductor,
    .Ensemble = .ensemble,
    .Movement = .movement,
    .MovementNumber = .movement_number,
    .ShowMovement = .show_movement,
    .Location = .location,
    .Mood = .mood,
    .MUSICBRAINZ_ARTISTID = .mb_artist_id,
    .MUSICBRAINZ_ALBUMARTISTID = .mb_album_artist_id,
    .MUSICBRAINZ_ALBUMID = .mb_album_id,
    .MUSICBRAINZ_TRACKID = .mb_track_id,
    .MUSICBRAINZ_RELEASETRACKID = .mb_release_track_id,
    .MUSICBRAINZ_RELEASEGROUPID = .mb_release_group_id,
    .MUSICBRAINZ_WORKID = .mb_work_id,
};
const Map = @TypeOf(mpd_map);

const MpdTags = std.meta.FieldEnum(Map);

/// Doc comments mostly copied from https://mpd.readthedocs.io/en/latest/protocol.html#tags
pub const Tags = struct {
    /// Not well-defined, see `composer` and `performer`
    artist: ?[]const u8 = null,
    /// Same as `artist` but for sorting. This usually omits prefixes such as "The"
    artist_sort: ?[]const u8 = null,
    /// Artist name that shall be used for the whole album in case tracks have different artists. Not well-defined
    album_artist: ?[]const u8 = null,
    /// Same as `album_artist` but for sorting
    album_artist_sort: ?[]const u8 = null,
    album: ?[]const u8 = null,
    /// Same as `album` but for sorting
    album_sort: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// Same as `title` but for sorting
    title_sort: ?[]const u8 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
    /// Not well-defined. This is not the song title, it is often used by badly configured internet radio stations with
    /// broken tags to squeeze both the artist name and the song title in one tag
    name: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    date: ?[]const u8 = null,
    original_date: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    /// Same as `composer` but for sorting
    composer_sort: ?[]const u8 = null,
    performer: ?[]const u8 = null,
    /// Not well-defined. Human-readable comment about this song
    comment: ?[]const u8 = null,
    /// Label or publisher
    label: ?[]const u8 = null,
    /// "used if the sound belongs to a larger category of sounds/music" – https://id3.org/id3v2.4.0-frames
    grouping: ?[]const u8 = null,
    /// "distinct intellectual or artistic creation, which can be expressed in the form of one or more audio recordings" – https://musicbrainz.org/doc/Work
    work: ?[]const u8 = null,
    conductor: ?[]const u8 = null,
    ensemble: ?[]const u8 = null,
    movement: ?[]const u8 = null,
    /// Can be Roman, therefore not an integer
    movement_number: ?[]const u8 = null,
    /// Whether a player should display the `work`, `movement`, and `movement_number` instead of `title`
    show_movement: ?bool = null,
    /// Location of the recording
    location: ?[]const u8 = null,
    /// Mood of the audio with few keywords
    mood: ?[]const u8 = null,

    /// Artist ID in the MusicBrainz database
    mb_artist_id: ?[]const u8 = null,
    /// Album artist ID in the MusicBrainz database
    mb_album_artist_id: ?[]const u8 = null,
    /// Album ID in the MusicBrainz database
    mb_album_id: ?[]const u8 = null,
    /// Track ID in the MusicBrainz database
    mb_track_id: ?[]const u8 = null,
    /// Release track ID in the MusicBrainz database
    mb_release_track_id: ?[]const u8 = null,
    /// Release group ID in the MusicBrainz database
    mb_release_group_id: ?[]const u8 = null,
    /// Work ID in the MusicBrainz database
    mb_work_id: ?[]const u8 = null,

    pub fn parseTag(self: *Tags, arena: std.mem.Allocator, kv: zmpd.KV) (std.fmt.ParseIntError || std.mem.Allocator.Error)!void {
        if (std.meta.stringToEnum(MpdTags, kv.key)) |key| switch (key) {
            .Track => self.track = try std.fmt.parseUnsigned(u32, kv.value, 10),
            .Disc => self.disc = try std.fmt.parseUnsigned(u32, kv.value, 10),
            .ShowMovement => self.show_movement = std.mem.eql(u8, kv.value, "1"),
            inline else => |tag| {
                @field(self, @tagName(@field(mpd_map, @tagName(tag)))) = try arena.dupe(u8, kv.value);
            },
        };
    }
};
