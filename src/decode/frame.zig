const std = @import("std");
const decodeBlock = @import("./block.zig").decodeBlock;
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
	if (magic == Frame.LZ4.magic_start) {
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

fn readLZ4Header(in_reader: anytype, comptime verify_checksums: bool) !Frame.LZ4.Header {
	// Count to be able to compute checksum without assuming in_reader is a block reader.
	var counting_reader = std.io.countingReader(in_reader);
	var reader = counting_reader.reader();

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
		var potential_header_bytes: [14]u8 = undefined;
		potential_header_bytes[0] = @bitCast(u8, descriptor);
		potential_header_bytes[1] = @bitCast(u8, block_descriptor);
		// TODO: lower @memcpy to a for loop because the source or destination iterable is a tuple
		if (descriptor.content_size) {
			const content_bytes = std.mem.toBytes(content_size);
			for (0..8) |i| potential_header_bytes[2 + i] = content_bytes[i];
		}
		if (descriptor.dict_id) {
			const dict_id_bytes = std.mem.toBytes(dictionary_id);
			for (0..4) |i| potential_header_bytes[10 + i] = dict_id_bytes[i];
		}

		const header_bytes = potential_header_bytes[0..counting_reader.bytes_read - 1];
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

fn maxDecompressedSize(size: Frame.LZ4.Header.BlockDescriptor.MaxSize) !usize {
	return switch (size) {
		._64KB => 64 * 1_000,
		._256KB => 256 * 1_000,
		._1MB => 1 * 1_000_000,
		._4MB => 4 * 1_000_000,
		else => DecodeError.InvalidMaxSize,
	};
}

fn readDataBlock(
	allocator: Allocator,
	header: Frame.LZ4.Header,
	reader: anytype,
	comptime verify_checksums: bool
) ![]u8 {
	const data_block = try reader.readStruct(Frame.LZ4.DataBlock);
	log.debug("data_block {any}", .{ data_block });

	const compressed = try allocator.alloc(u8, data_block.block_size);
	defer allocator.free(compressed);
	const n_read = try reader.read(compressed);
	if (compressed.len != n_read) {
		log.err("premature data block end. expected {d} bytes but got {d}", .{ compressed.len, n_read });
		return DecodeError.PrematureEnd;
	}

	if (header.descriptor.block_checksum) {
		const expected_checksum = try reader.readIntLittle(u32);
		if (verify_checksums) {
			const actual_checksum = Hasher.hash(compressed);
			if (expected_checksum != actual_checksum) {
				log.warn("expected block checksum {x}, got {x}", .{ expected_checksum, actual_checksum });
				return DecodeError.ChecksumMismatch;
			}
		}
	}

	const decompressed = if (!data_block.uncompressed)
		try decodeBlock(allocator, compressed)
	else compressed;

	if (header.content_size > 0 and verify_checksums and header.content_size != decompressed.len) {
		log.err("expected content size {d}, got {d}", .{ header.content_size, decompressed.len });
	}

	return decompressed;
}

pub fn readFrame(allocator: Allocator, reader: anytype, comptime verify_checksums: bool) ![]u8 {
	switch (try readFrameHeader(reader, verify_checksums)) {
		.skippable => |header| {
			try reader.skipBytes(header.frame_size, .{});
			return &.{};
		},
		.lz4 => |header| {
			log.debug("header {any}", .{ header });

			const res = try readDataBlock(allocator, header, reader, verify_checksums);

			const end_magic = try reader.readIntLittle(Frame.LZ4.Magic);
			log.debug("end magic {x}", .{ end_magic });
			if (end_magic != Frame.LZ4.magic_end) return DecodeError.BadEndMagic;

			if (header.descriptor.content_checksum and verify_checksums) {
				const expected_checksum = try reader.readIntLittle(u32);
				const actual_checksum = Hasher.hash(res);
				if (expected_checksum != actual_checksum) {
					log.warn("expected header checksum {x}, got {x}", .{ expected_checksum, actual_checksum });
					return DecodeError.ChecksumMismatch;
				}
			}

			return res;
		}
	}
}

test "read frame" {
	const src = @embedFile("./testdata/small.txt.lz4");
	const expected = @embedFile("./testdata/small.txt");

	const allocator = std.testing.allocator;

	var stream = std.io.fixedBufferStream(src);
	var reader = stream.reader();
	const decompressed = try readFrame(allocator, reader, true);
	defer allocator.free(decompressed);

	try std.testing.expectEqualSlices(u8, expected, decompressed);
}
