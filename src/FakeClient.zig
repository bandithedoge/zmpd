//! A client that doesn't connect to anything, made for simulating responses in unit tests.
//!
//! Use `setResponse` to mock an MPD response before each call to functions in `zmpd.Client`.

const std = @import("std");
const zmpd = @import("zmpd.zig");

const FakeClient = @This();

allocator: std.mem.Allocator,
options: zmpd.Client.InitOptions,
buffer: []u8,
writer: std.Io.Writer,
response: []u8,
reader: std.Io.Reader,

pub fn init(allocator: std.mem.Allocator) !FakeClient {
    const options = zmpd.Client.InitOptions{};
    const buffer = try allocator.alloc(u8, options.buffer_size);
    const response = try allocator.alloc(u8, options.buffer_size);

    return .{
        .allocator = allocator,
        .options = options,
        .buffer = buffer,
        .writer = std.Io.Writer.fixed(buffer),
        .response = response,
        .reader = .fixed(
            // expected response after connecting and sending 'binarylimit'
            \\OK MPD 0.24.0
            \\OK
        ),
    };
}

pub fn deinit(self: *const FakeClient) void {
    self.allocator.free(self.buffer);
    self.allocator.free(self.response);
}

pub fn client(self: *FakeClient) !zmpd.Client {
    return try .init(&self.writer, &self.reader, self.options);
}

pub fn setResponse(self: *FakeClient, fake_response: []const u8) void {
    self.reader.buffer = @constCast(fake_response);
    self.reader.seek = 0;
    self.reader.end = fake_response.len;
}

fn fakeStream(r: *std.Io.Reader, w: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const fake_client: *FakeClient = @fieldParentPtr("reader", r);
    std.debug.print("{s}\n", .{fake_client.response});
    try w.writeAll(fake_client.response);
    return fake_client.response.len;
}
