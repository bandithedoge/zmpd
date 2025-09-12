//! Doc comments mostly copied from https://mpd.readthedocs.io/en/latest/protocol.html#tags

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
        // https://github.com/MusicPlayerDaemon/libmpdclient/blob/cc2f3e0199520c93ca28c5deb4520c938b8cdebb/src/tag.c#L10-L51
        return switch (self) {
            .artist => "Artist",
            .artist_sort => "ArtistSort",
            .album_artist => "AlbumArtist",
            .album_artist_sort => "AlbumArtistSort",
            .album => "Album",
            .album_sort => "AlbumSort",
            .title => "Title",
            .title_sort => "TitleSort",
            .track => "Track",
            .disc => "Disc",
            .name => "Name",
            .genre => "Genre",
            .date => "Date",
            .original_date => "OriginalDate",
            .composer => "Composer",
            .composer_sort => "ComposerSort",
            .performer => "Performer",
            .comment => "Comment",
            .label => "Label",
            .grouping => "Grouping",
            .work => "Work",
            .conductor => "Conductor",
            .ensemble => "Ensemble",
            .movement => "Movement",
            .movement_number => "MovementNumber",
            .show_movement => "ShowMovement",
            .location => "Location",
            .mood => "Mood",
            .mb_artist_id => "MUSICBRAINZ_ARTISTID",
            .mb_album_artist_id => "MUSICBRAINZ_ALBUMARTISTID",
            .mb_album_id => "MUSICBRAINZ_ALBUMID",
            .mb_track_id => "MUSICBRAINZ_TRACKID",
            .mb_release_track_id => "MUSICBRAINZ_RELEASETRACKID",
            .mb_release_group_id => "MUSICBRAINZ_RELEASEGROUPID",
            .mb_work_id => "MUSICBRAINZ_WORKID",
        };
    }

    pub fn format(self: Tag, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.string());
    }
};

pub const Tags = struct {
    arena: std.heap.ArenaAllocator,

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

    pub fn parseTag(self: *Tags, kv: zmpd.KV) (std.fmt.ParseIntError || std.mem.Allocator.Error)!void {
        const allocator = self.arena.allocator();

        if (std.mem.eql(u8, kv.key, "Artist"))
            self.artist = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "ArtistSort"))
            self.artist_sort = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "AlbumArtist"))
            self.album_artist = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "AlbumArtistSort"))
            self.album_artist_sort = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Album"))
            self.album = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "AlbumSort"))
            self.album_sort = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Title"))
            self.title = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "TitleSort"))
            self.title_sort = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Track"))
            self.track = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "Disc"))
            self.disc = try std.fmt.parseUnsigned(u32, kv.value, 10)
        else if (std.mem.eql(u8, kv.key, "Name"))
            self.name = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Genre"))
            self.genre = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Date"))
            self.date = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "OriginalDate"))
            self.original_date = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Composer"))
            self.composer = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "ComposerSort"))
            self.composer_sort = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Performer"))
            self.performer = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Comment"))
            self.comment = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Label"))
            self.label = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Grouping"))
            self.grouping = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Work"))
            self.work = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Conductor"))
            self.conductor = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Ensemble"))
            self.ensemble = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Movement"))
            self.movement = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MovementNumber"))
            self.movement_number = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "ShowMovement"))
            self.show_movement = std.mem.eql(u8, kv.value, "1")
        else if (std.mem.eql(u8, kv.key, "Location"))
            self.location = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "Mood"))
            self.mood = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MUSICBRAINZ_ARTISTID"))
            self.mb_artist_id = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MUSICBRAINZ_ALBUMARTISTID"))
            self.mb_album_artist_id = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MUSICBRAINZ_ALBUMID"))
            self.mb_album_id = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MUSICBRAINZ_TRACKID"))
            self.mb_track_id = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MUSICBRAINZ_RELEASETRACKID"))
            self.mb_release_track_id = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MUSICBRAINZ_RELEASEGROUPID"))
            self.mb_release_group_id = try allocator.dupe(u8, kv.value)
        else if (std.mem.eql(u8, kv.key, "MUSICBRAINZ_WORKID"))
            self.mb_work_id = try allocator.dupe(u8, kv.value);
    }

    pub inline fn deinit(self: *const Tags) void {
        self.arena.deinit();
    }
};

test "FieldEnum(Tags) = Tag" {
    try std.testing.expectEqualSlices(
        []const u8,
        std.meta.fieldNames(Tag),
        std.meta.fieldNames(Tags)[1..], // ignore arena
    );
}
