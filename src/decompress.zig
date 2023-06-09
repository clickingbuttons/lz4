const std = @import("std");
const block = @import("./decode/block.zig");
const frame = @import("./decode/frame.zig");

const log = std.log.scoped(.lz4_decompress);

pub fn DecompressStream(
    comptime ReaderType: type,
    comptime verify_checksums: bool,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        source: ReaderType,

        header: ?frame.FrameHeader,
        data: []u8,
        offset: usize,

        pub const Error = ReaderType.Error || block.DecodeError || frame.DecodeError || error{OutOfMemory};
        pub const Reader = std.io.Reader(*Self, Error, read);

        pub fn init(allocator: std.mem.Allocator, source: ReaderType) Self {
            return .{
                .allocator = allocator,
                .source = source,
                .header = null,
                .data = &.{},
                .offset = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn read(self: *Self, buffer: []u8) Error!usize {
            if (buffer.len == 0) return 0;

            var len: usize = 0;
            if (self.offset < self.data.len) {
                len = @min(buffer.len, self.data.len - self.offset);
                @memcpy(buffer[0..len], self.data[self.offset .. self.offset + len]);
                self.offset += len;
            }

            if (buffer.len > len) {
                self.data = frame.decode(self.allocator, self.source, verify_checksums) catch |err| {
                    if (err == error.EndOfStream) return len;
                    return @as(Error, @errSetCast(err));
                };
                return try self.read(buffer[len..]);
            }

            return len;
        }
    };
}

/// Returns a struct that implements a Reader interface for a stream of LZ4 frames.
pub fn decompressStream(
    allocator: std.mem.Allocator,
    reader: anytype,
    comptime verify_checksums: bool,
) DecompressStream(@TypeOf(reader), verify_checksums) {
    return DecompressStream(@TypeOf(reader), verify_checksums).init(allocator, reader);
}

fn testDecompress(comptime fname: []const u8) !void {
    const allocator = std.testing.allocator;
    const expected = try std.fs.cwd().readFileAlloc(allocator, fname, 1_000_000_000);
    defer allocator.free(expected);

    var file = try std.fs.cwd().openFile(fname ++ ".lz4", .{});
    var reader = file.reader();
    var stream = decompressStream(std.testing.allocator, reader, true);
    defer stream.deinit();
    var lz4reader = stream.reader();
    var buf: []u8 = try allocator.alloc(u8, expected.len * 4);
    defer allocator.free(buf);
    const res = try lz4reader.read(buf);
    try std.testing.expectEqual(@as(usize, expected.len), res);
    try std.testing.expectEqualStrings(expected, buf[0..expected.len]);
}

test "decompress small" {
    try testDecompress("./testdata/small.txt");
}

test "decompress large" {
    try testDecompress("./testdata/lorem.txt");
}
