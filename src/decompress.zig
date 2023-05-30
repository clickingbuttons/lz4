const std = @import("std");
const block = @import("./decode/block.zig");
const frame = @import("./decode/frame.zig");

const log = std.log.scoped(.lz4_decompress);

pub const DecompressStreamOptions = struct {
	verify_checksums: bool = true,
};

pub fn DecompressStream(
	comptime ReaderType: type,
	comptime options: DecompressStreamOptions,
) type {
	return struct {
		const Self = @This();

		allocator: std.mem.Allocator,
		source: ReaderType,

		header: ?frame.FrameHeader,
		data: []u8,
		offset: usize,

		pub const Error = ReaderType.Error || block.DecodeError || frame.DecodeError || error {
			OutOfMemory
		};
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
				@memcpy(buffer[0..len], self.data[self.offset..self.offset + len]);
				self.offset += len;
			}

			if (buffer.len > len) {
				self.data = frame.decodeFrame(self.allocator, self.source, options.verify_checksums) catch |err| {
					return switch (err) {
						error.AccessDenied => Error.AccessDenied,
						error.BadEndMagic => Error.BadEndMagic,
						error.BadMatchLen => Error.BadMatchLen,
						error.BadMatchOffset => Error.BadMatchOffset,
						error.BadStartMagic => Error.BadStartMagic,
						error.BrokenPipe => Error.BrokenPipe,
						error.ChecksumMismatch => Error.ChecksumMismatch,
						error.ConnectionResetByPeer => Error.ConnectionResetByPeer,
						error.ConnectionTimedOut => Error.ConnectionTimedOut,
						error.DictionaryUnsupported => Error.DictionaryUnsupported,
						error.EndOfStream => len, // End of stream is OK
						error.InputOutput => Error.InputOutput,
						error.InvalidMaxSize => Error.InvalidMaxSize,
						error.InvalidVersion => Error.InvalidVersion,
						error.IsDir => Error.IsDir,
						error.NetNameDeleted => Error.NetNameDeleted,
						error.NotOpenForReading => Error.NotOpenForReading,
						error.OperationAborted => Error.OperationAborted,
						error.OutOfMemory => Error.OutOfMemory,
						error.PrematureEnd => Error.PrematureEnd,
						error.ReservedBitSet => Error.ReservedBitSet,
						error.SystemResources => Error.SystemResources,
						error.Unexpected => Error.Unexpected,
						error.WouldBlock => Error.WouldBlock,
					};
				};
				return try self.read(buffer[len..]);
			}

			return len;
		}
	};
}

pub fn decompressStreamOptions(
	allocator: std.mem.Allocator,
	reader: anytype,
	comptime options: DecompressStreamOptions,
) DecompressStream(@TypeOf(reader, options)) {
	return DecompressStream(@TypeOf(reader), options).init(allocator, reader);
}

pub fn decompressStream(
	allocator: std.mem.Allocator,
	reader: anytype,
) DecompressStream(@TypeOf(reader), .{}) {
	return DecompressStream(@TypeOf(reader), .{}).init(allocator, reader);
}

fn testDecompress(comptime fname: []const u8) !void {
	const allocator = std.testing.allocator;
	const expected = try std.fs.cwd().readFileAlloc(allocator, fname, 1_000_000_000);
	defer allocator.free(expected);

	var file = try std.fs.cwd().openFile(fname ++ ".lz4", .{});
	var reader = file.reader();
	var stream = decompressStream(std.testing.allocator, reader);
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
