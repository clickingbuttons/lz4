const std = @import("std");
const decodeBlockArrayList = @import("./block.zig").decodeBlockArrayList;
const Frame = @import("../types.zig").Frame;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.lz4_frame);

pub const DecodeError = error {
	BadStartMagic,
	BadEndMagic,
	ReservedBitSet,
	InvalidVersion,
	PrematureEnd,
	DictionaryUnsupported,
	ChecksumMismatch,
	InvalidMaxSize,
};

pub const FrameHeader = union(Frame.Kind) {
	lz4: Frame.LZ4.Header,
	skippable: Frame.Skippable.Header,
};

const Hasher = std.hash.XxHash32; 

inline fn isSkippableMagic(magic: Frame.LZ4.Magic) bool {
	return Frame.Skippable.Header.magic_min <= magic and magic <= Frame.Skippable.Header.magic_max;
}

inline fn frameType(magic: Frame.LZ4.Magic) DecodeError!Frame.Kind {
	if (magic == Frame.LZ4.magic) {
		return .lz4;
	} else if (isSkippableMagic(magic)) {
		return .skippable;
	}

	log.err("invalid start magic {x}", .{ magic });
	return DecodeError.BadStartMagic;
}

fn headerChecksum(src: []const u8) u8 {
	const hash = Hasher.hash(src);
	return @truncate(u8, hash >> 8);
}

fn readLZ4Header(reader: anytype, comptime verify_checksums: bool) !Frame.LZ4.Header {
	const descriptor = @bitCast(Frame.LZ4.Header.Descriptor, try reader.readByte());
	if (descriptor._reserved) return DecodeError.ReservedBitSet;
	if (descriptor.version != 1) return DecodeError.InvalidVersion;
	if (descriptor.dict_id) return DecodeError.DictionaryUnsupported;

	const block_descriptor = @bitCast(Frame.LZ4.Header.BlockDescriptor, try reader.readByte());
	if (block_descriptor._reserved1 or block_descriptor._reserved2 != 0) {
		return DecodeError.ReservedBitSet;
	}

	// Struct field order is not guarunteed.
	const content_size = if (descriptor.content_size) try reader.readIntLittle(u64) else 0;
	const dictionary_id = if (descriptor.dict_id) try reader.readIntLittle(u32) else 0;

	const expected_checksum = try reader.readByte();
	// Official implementation only checks checksums in testing mode.
	if (verify_checksums) {
		var header_len: usize = 2;
		var potential_header_bytes: [14]u8 = undefined;
		potential_header_bytes[0] = @bitCast(u8, descriptor);
		potential_header_bytes[1] = @bitCast(u8, block_descriptor);
		// TODO: lower @memcpy to a for loop because the source or destination iterable is a tuple
		if (descriptor.content_size) {
			header_len += @sizeOf(u64);
			const content_bytes = std.mem.toBytes(content_size);
			for (0..8) |i| potential_header_bytes[2 + i] = content_bytes[i];
		}
		if (descriptor.dict_id) {
			header_len += @sizeOf(u32);
			const dict_id_bytes = std.mem.toBytes(dictionary_id);
			for (0..4) |i| potential_header_bytes[10 + i] = dict_id_bytes[i];
		}

		log.debug("header len {d}", .{ header_len });
		const header_bytes = potential_header_bytes[0..header_len];
		const actual_checksum = headerChecksum(header_bytes);

		if (expected_checksum != actual_checksum) {
			log.warn("expected header checksum {x}, got {x}", .{ expected_checksum, actual_checksum });
			return DecodeError.ChecksumMismatch;
		}
	}

	return .{
		.descriptor = descriptor,
		.block_descriptor = block_descriptor,
		.content_size = content_size,
		.dictionary_id = dictionary_id,
		.checksum = expected_checksum,
	};
}

test "xxhash" {
	try std.testing.expectEqual(@as(u8, 0xa7), headerChecksum(&[_]u8{ 0x64, 0x40 }));
}

fn readFrameHeader(reader: anytype, comptime verify_checksums: bool) !FrameHeader {
	const magic = try reader.readIntLittle(u32);
	const frame_type = try frameType(magic);
	return switch (frame_type) {
		.lz4 => FrameHeader{ .lz4 = try readLZ4Header(reader, verify_checksums) },
		.skippable => FrameHeader{
			.skippable = .{
				.magic_number = magic,
				.frame_size = try reader.readIntLittle(u32),
			},
		},
	};
}

fn readDataBlockChecksum(reader: anytype, data: []const u8, comptime verify_checksums: bool) !void {
	const expected_checksum = try reader.readIntLittle(u32);
	if (verify_checksums) {
		const actual_checksum = Hasher.hash(data);
		if (expected_checksum != actual_checksum) {
			log.warn("expected block checksum {x}, got {x}", .{ expected_checksum, actual_checksum });
			return DecodeError.ChecksumMismatch;
		}
	}
}

fn readDataBlock(
	allocator: Allocator,
	header: Frame.LZ4.Header,
	reader: anytype,
	out: *std.ArrayList(u8),
	comptime verify_checksums: bool,
) !usize {
	const data_block = try reader.readStruct(Frame.LZ4.DataBlock);
	log.debug("data_block {any}", .{ data_block });

	if (data_block.block_size == 0) return 0;

	const old_len = out.items.len;
	var n_read: usize = 0;
	if (data_block.uncompressed) {
		try out.resize(old_len + data_block.block_size);
		n_read = try reader.read(out.items[old_len..]);

		if (header.descriptor.block_checksum) {
			try readDataBlockChecksum(reader, out.items[old_len..], verify_checksums);
		}
	} else {
		const compressed = try allocator.alloc(u8, data_block.block_size);
		defer allocator.free(compressed);
		n_read = try reader.read(compressed);

		if (header.descriptor.block_checksum) {
			try readDataBlockChecksum(reader, compressed, verify_checksums);
		}

		_ = try decodeBlockArrayList(out, compressed);
	}

	if (data_block.block_size != n_read) {
		log.err("premature data block end. expected {d} bytes but got {d}", .{ data_block.block_size, n_read });
		return DecodeError.PrematureEnd;
	}

	const res = out.items.len - old_len;
	if (verify_checksums and header.content_size > 0 and header.content_size != res) {
		log.warn("expected content size {d}, got {d}", .{ header.content_size, res });
	}

	return res;
}

pub fn decodeFrame(allocator: Allocator, reader: anytype, comptime verify_checksums: bool) ![]u8 {
	switch (try readFrameHeader(reader, verify_checksums)) {
		.skippable => |header| {
			try reader.skipBytes(header.frame_size, .{});
			return &.{};
		},
		.lz4 => |header| {
			log.debug("header {any}", .{ header });

			var decoded = std.ArrayList(u8).init(allocator);
			errdefer decoded.deinit();

			var len: usize = 0;
			while (true) {
				const read = try readDataBlock(allocator, header, reader, &decoded, verify_checksums);
				if (read == 0) break;
				len += read;
			}

			if (header.descriptor.content_checksum and verify_checksums) {
				const expected_checksum = try reader.readIntLittle(u32);
				const actual_checksum = Hasher.hash(decoded.items);
				if (expected_checksum != actual_checksum) {
					log.warn("expected content checksum {x} from frame, got {x}", .{ expected_checksum, actual_checksum });
					return DecodeError.ChecksumMismatch;
				}
			}

			return decoded.toOwnedSlice();
		}
	}
}

test "read compressed frame" {
	const src = [_]u8 {0x04, 0x22, 0x4d, 0x18} // magic
		++ [_]u8{0x7c, 0x40, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88} // frame descriptor
		++ [_]u8{0x32, 0x00, 0x00, 0x00} // data block length
		++ "\xb3Hello there\x06\x00" // data block
		++ "\xf0\x13I am a sentence to be compressed\x2e\x0a"
		++ [_]u8 {0x0f, 0x60, 0x99, 0x2b} // data block checksum
		++ [_]u8 {0x00, 0x00, 0x00, 0x00} // end mark
		++ [_]u8 {0x0d, 0xcd, 0xd5, 0x32} // content checksum
	;
	const expected = "Hello there there I am a sentence to be compressed.\n";

	const allocator = std.testing.allocator;

	var stream = std.io.fixedBufferStream(src);
	var reader = stream.reader();
	const decompressed = try decodeFrame(allocator, reader, true);
	defer allocator.free(decompressed);

	try std.testing.expectEqualSlices(u8, expected, decompressed);
}

test "read two frames" {
	const src = [_]u8{0x04, 0x22, 0x4d, 0x18} // magic
		++ [_]u8{0x64, 0x40, 0xa7} // frame descriptor
		++ [_]u8{0x20, 0x00, 0x00, 0x80} // data block length (32)
		++ "This is more than 64 bytes which"
		++ [_]u8{0x20, 0x00, 0x00, 0x80} // data block length (32)
		++ " will make it into three frames "
		++ [_]u8{0x11, 0x00, 0x00, 0x80} // data block length (17)
		++ "with `lz4 -B32`.\x0a"
		++ [_]u8{0x0, 0x0, 0x0, 0x0} // end mark
		++ [_]u8{0x03, 0xa5, 0x58, 0xf6} // content checksum
	;
	const expected = "This is more than 64 bytes which will make it into three frames with `lz4 -B32`.\n";

	const allocator = std.testing.allocator;

	var stream = std.io.fixedBufferStream(src);
	var reader = stream.reader();
	const decompressed = try decodeFrame(allocator, reader, true);
	defer allocator.free(decompressed);

	try std.testing.expectEqualSlices(u8, expected, decompressed);
}

test "bad frames don't leak memory" {
	const src = [_]u8{0x04, 0x22, 0x4d, 0x18} // magic
		++ [_]u8{0x64, 0x40, 0xa7} // frame descriptor
		++ [_]u8{0x20, 0x00, 0x00, 0x80} // data block length (32)
		++ "This is something longer than 32 bytes which will cause problems"
		++ [_]u8{0x0, 0x0, 0x0, 0x0} // end mark
		++ [_]u8{0x03, 0xa5, 0x58, 0xf6} // content checksum (incorrect)
	;

	const allocator = std.testing.allocator;

	var stream = std.io.fixedBufferStream(src);
	var reader = stream.reader();
	try std.testing.expectError(error.BadMatchOffset, decodeFrame(allocator, reader, true));
}
