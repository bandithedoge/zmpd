Supports Zig 0.15.1.

# Features

- No dependencies beside the Zig standard library (not even libc)
- No runtime allocations (except for copying strings), primarily iterator-based API
- Portable implementation based on `std.Io.Reader` and `std.Io.Writer` (a basic default implementation is provided)

# Usage

```sh
$ zig fetch --save https://github.com/bandithedoge/zmpd/archive/<COMMIT_HASH>.tar.gz
```

In `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zmpd = b.dependency("zmpd", .{
        .target = target,
        .optimize = optimize,
        .assert_version = true, // defaults to true if optimize == .Debug
    })

    // const exe = ...

    exe.root_module.addImport("zmpd", zmpd.module("zmpd"));

    b.installArtifact(exe);
}
```

In your source file:

```zig
const zmpd = @import("zmpd");

pub fn main() !void {
    // const allocator = ...

    // Opens a new connection to the daemon using the standard library's TCP or Unix socket implementation.
    // For more control, see `zmpd.Connection.init` and `zmpd.Client.init`
    var connection = try zmpd.connect(allocator, .{});
    defer connection.deinit();

    // This is where most of your interaction with the daemon happens.
    var client = try connection.client();

    // Let's print the currently playing song...
    var song = try client.getCurrentSong(allocator);
    defer song.deinit();
    std.debug.print("{s} - {s}\n", .{ song.tags.artist.?, song.tags.title.? });

    // I've changed my mind
    try client.next();
}
```

# Protocol coverage

0.24 is the latest supported protocol version.

- [x] [Querying MPD's status](https://mpd.readthedocs.io/en/stable/protocol.html#querying-mpd-s-status)
- [x] [Playback options](https://mpd.readthedocs.io/en/stable/protocol.html#playback-options)
- [x] [Controlling playback](https://mpd.readthedocs.io/en/stable/protocol.html#controlling-playback)
- [x] [The Queue](https://mpd.readthedocs.io/en/stable/protocol.html#the-queue)
- [x] [Stored playlists](https://mpd.readthedocs.io/en/stable/protocol.html#stored-playlists)
- [x] [The music database](https://mpd.readthedocs.io/en/stable/protocol.html#the-music-database)
- [ ] [Mounts and neighbors](https://mpd.readthedocs.io/en/stable/protocol.html#mounts-and-neighbors)
- [ ] [Stickers](https://mpd.readthedocs.io/en/stable/protocol.html#stickers)
- [ ] [Connection settings](https://mpd.readthedocs.io/en/stable/protocol.html#connection-settings)
- [ ] [Partition commands](https://mpd.readthedocs.io/en/stable/protocol.html#partition-commands)
- [ ] [Audio output devices](https://mpd.readthedocs.io/en/stable/protocol.html#audio-output-devices)
- [ ] [Reflection](https://mpd.readthedocs.io/en/stable/protocol.html#reflection)
- [ ] [Client to client](https://mpd.readthedocs.io/en/stable/protocol.html#client-to-client)
