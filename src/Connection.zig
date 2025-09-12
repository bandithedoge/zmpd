const std = @import("std");
const zmpd = @import("zmpd.zig");

const Connection = @This();

allocator: std.mem.Allocator,
options: zmpd.Client.InitOptions,
stream: std.net.Stream,
writer: std.net.Stream.Writer,
writer_buffer: []u8,
reader: std.net.Stream.Reader,
reader_buffer: []u8,

pub fn init(allocator: std.mem.Allocator, address: std.net.Address, options: zmpd.Client.InitOptions) !Connection {
    const writer_buffer = try allocator.alloc(u8, options.buffer_size);
    const reader_buffer = try allocator.alloc(u8, options.buffer_size);

    const stream = switch (address.any.family) {
        std.posix.AF.UNIX => try std.net.connectUnixSocket(std.mem.sliceTo(&address.un.path, 0)),
        else => try std.net.tcpConnectToAddress(address),
    };

    return .{
        .allocator = allocator,
        .options = options,
        .stream = stream,
        .writer = stream.writer(writer_buffer),
        .writer_buffer = writer_buffer,
        .reader = stream.reader(reader_buffer),
        .reader_buffer = reader_buffer,
    };
}

pub fn client(self: *Connection) !zmpd.Client {
    return try .init(&self.writer.interface, self.reader.interface(), self.options);
}

pub fn deinit(self: *Connection) void {
    self.stream.close();
    self.allocator.free(self.reader_buffer);
    self.allocator.free(self.writer_buffer);
}
