const std = @import("std");
const zmpd = @import("zmpd.zig");

const Connection = @This();

allocator: std.mem.Allocator,
io: std.Io,
options: zmpd.Client.InitOptions,
stream: std.Io.net.Stream,
writer: std.Io.net.Stream.Writer,
writer_buffer: []u8,
reader: std.Io.net.Stream.Reader,
reader_buffer: []u8,

pub fn init(allocator: std.mem.Allocator, io: std.Io, address: zmpd.Address, options: zmpd.Client.InitOptions) !Connection {
    const writer_buffer = try allocator.alloc(u8, options.buffer_size);
    const reader_buffer = try allocator.alloc(u8, options.buffer_size);

    const stream = switch (address) {
        .unix => |add| try add.connect(io),
        .ip => |add| try add.connect(io, .{
            .mode = .stream,
            .protocol = .tcp,
        }),
    };

    return .{
        .allocator = allocator,
        .io = io,
        .options = options,
        .stream = stream,
        .writer = stream.writer(io, writer_buffer),
        .writer_buffer = writer_buffer,
        .reader = stream.reader(io, reader_buffer),
        .reader_buffer = reader_buffer,
    };
}

pub fn client(self: *Connection) !zmpd.Client {
    return try .init(&self.writer.interface, &self.reader.interface, self.options);
}

pub fn deinit(self: *Connection) void {
    self.stream.close(self.io);
    self.allocator.free(self.reader_buffer);
    self.allocator.free(self.writer_buffer);
}
