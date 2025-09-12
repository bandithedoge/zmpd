const std = @import("std");

pub const options = @import("options");
pub const Client = @import("Client.zig");
pub const Connection = @import("Connection.zig");

// TODO: error types for command-specific errors, see ResponseIterator.last_error_msg
pub const ProtocolError = error{
    NotList,
    Arg,
    Password,
    Permission,
    Unknown,
    NoExist,
    PlaylistMax,
    System,
    PlaylistLoad,
    UpdateAlready,
    PlayerSync,
    Exist,
};

/// Open an MPD connection using the standard library's TCP/socked with reasonable defaults. See `Connection.init` and
/// `Client.init` for more options.
pub fn connect(allocator: std.mem.Allocator, init_options: Client.InitOptions) !Connection {
    return .init(allocator, try guessAddress(allocator), init_options);
}

/// Guesses the address of the running MPD server from available environment variables and UNIX sockets (if available
/// on the target) in the following order:
/// - `$MPD_HOST:$MPD_PORT`
/// - `$MPD_HOST:6600`
/// - `$XDG_RUNTIME_DIR/mpd/socket`
/// - `/run/mpd/socket`
/// - `localhost:$MPD_PORT`
/// - `localhost:6600`
///
/// Use `connect` if you just want to open a connection from the same rules using the standard library's TCP stream.
///
/// https://mpd.readthedocs.io/en/latest/client.html#connecting-to-mpd
pub fn guessAddress(allocator: std.mem.Allocator) !std.net.Address {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const port = if (env_map.get("MPD_PORT")) |p|
        try std.fmt.parseInt(u16, p, 10)
    else
        6600;

    if (env_map.get("MPD_HOST")) |host|
        return try .resolveIp(host, port);

    if (std.net.has_unix_sockets) blk: {
        if (env_map.get("XDG_RUNTIME_DIR")) |xdg_runtime_dir| {
            const path = try std.fs.path.join(allocator, &.{ xdg_runtime_dir, "mpd", "socket" });
            defer allocator.free(path);
            return try .initUnix(path);
        }

        std.fs.accessAbsolute("/run/mpd/socket", .{ .mode = .read_write }) catch break :blk;

        return try .initUnix("/run/mpd/socket");
    }

    return .initIp4(.{ 127, 0, 0, 1 }, port);
}

pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

comptime {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Connection);
}
