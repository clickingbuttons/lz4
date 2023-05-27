const std = @import("std");
const block = @import("./decode/block.zig");
const frame = @import("./decode/frame.zig");

const log = std.log.scoped(.lz4_decompress);

pub const DecompressStreamOptions = struct {
	verify_checksum: bool = true,
};

pub fn DecompressStream(
	comptime ReaderType: type,
	comptime options: DecompressStreamOptions,
) type {
	return struct {
		const Self = @This();

		allocator: std.mem.Allocator,
		reader: ReaderType,

		header: ?frame.FrameHeader,
		data: []u8,
		offset: usize,

		pub const Error = ReaderType.Error || block.DecodeError || frame.DecodeError; 
		pub const Reader = std.io.Reader(*Self, Error, read);

		pub fn init(allocator: std.mem.Allocator, reader: ReaderType) Self {
			return .{
				.allocator = allocator,
				.reader = reader,
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

		fn read2(self: *Self, buffer: []u8) Error!usize {
			const old_offset = self.offset;
			if (self.offset < self.data.len) {
				// We have data ready to write
				const len = @min(buffer.len, self.data.len - self.offset);
				@memcpy(buffer, self.data[self.offset..self.offset + len]);
				self.offset += buffer.len;
			}
			if (self.data.len - self.offset >= buffer.len) {
			}
			self.data = try frame.readFrame(self.allocator, reader, self.options.verify_checksums);
		}

		pub fn read(self: *Self, buffer: []u8) Error!usize {
			if (buffer.len == 0) return 0;

			while (true) {
				const size = try self.read2(buffer);
				if (size > 0) return size;
			}
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
