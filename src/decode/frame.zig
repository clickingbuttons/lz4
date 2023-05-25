const std = @import("std");
const builtin = @import("builtin");
const decodeBlock = @import("./block.zig").decodeBlock;
const Frame = @import("../types.zig").Frame;

const log = std.log.scoped(.lz4_frame);

pub const LZ4DecodeFrameError = error {
	BadStartMagic,
	BadEndMagic,
	EndOfStream,
	ReservedBitSet,
	InvalidVersion,
};

pub const FrameHeader = union(enum) {
	lz4: Frame.LZ4.Header,
	skippable: Frame.Skippable.Header,
};

const Hasher = std.hash.XxHash32; 

inline fn isSkippableMagic(magic: Frame.LZ4.Magic) bool {
	return Frame.Skippable.Header.magic_min <= magic and magic <= Frame.Skippable.Header.magic_max;
}

inline fn frameType(magic: Frame.LZ4.Magic) LZ4DecodeFrameError!Frame.Kind {
	return if (magic == Frame.LZ4.magic_start)
		.lz4
	else if (isSkippableMagic(magic))
		.skippable
	else
		LZ4DecodeFrameError.BadStartMagic;
}

fn headerChecksum(src: []const u8) u8 {
	const hash = Hasher.hash(src);
	return @truncate(u8, hash >> 8);
}

fn decodeHeader(reader: anytype) !Frame.LZ4.Header {
	const descriptor = @bitCast(Frame.LZ4.Header.Descriptor, try reader.readByte());
	if (descriptor._reserved) return LZ4DecodeFrameError.ReservedBitSet;

	if (descriptor.version != 1) return LZ4DecodeFrameError.InvalidVersion;

	const block_descriptor = @bitCast(Frame.LZ4.Header.BlockDescriptor, try reader.readByte());
	if (block_descriptor._reserved1 or block_descriptor._reserved2 != 0) return LZ4DecodeFrameError.ReservedBitSet;

	// Struct field order is not guarunteed.
	const content_size = if (descriptor.content_size) try reader.readIntLittle(u64) else 0;
	const dictionary_id = if (descriptor.dict_id) try reader.readIntLittle(u32) else 0;

	const checksum = try reader.readByte();
	if (builtin.mode == .Debug) {
		// log.debug("read header size {d}", .{ reader.context.pos });
		const magic_offset = @sizeOf(Frame.LZ4.Magic);
		const descriptor_len = reader.context.pos - magic_offset - 1;
		const descriptor_bytes = reader.context.buffer[magic_offset..magic_offset + descriptor_len];
		const computed_checksum = headerChecksum(descriptor_bytes);
		std.debug.assert(computed_checksum == checksum);
	}

	return .{
		.descriptor = descriptor,
		.block_descriptor = block_descriptor,
		.content_size = content_size,
		.dictionary_id = dictionary_id,
		.checksum = checksum,
	};
}

test "xxhash" {
	try std.testing.expectEqual(@as(u8, 0xa7), headerChecksum(&[_]u8{ 0x64, 0x40 }));
}

fn readFrameHeader(reader: anytype) !FrameHeader {
	const magic = try reader.readIntLittle(u32);
	const frame_type = try frameType(magic);
	return switch (frame_type) {
		.lz4 => FrameHeader{ .lz4 = try decodeHeader(reader) },
		.skippable => FrameHeader{
			.skippable = .{
				.magic_number = magic,
				.frame_size = try reader.readIntLittle(u32),
			},
		},
	};
}

pub fn decodeFrame(dest: []u8, src: []const u8) !usize {
	var stream = std.io.fixedBufferStream(src);
	var reader = stream.reader();

	switch (try readFrameHeader(reader)) {
		.skippable => |header| return try reader.read(dest[0..header.frame_size]),
		.lz4 => |header| {
			log.debug("header {any}", .{ header });

			const block_descriptor = try reader.readStruct(Frame.LZ4.DataBlock);
			log.debug("block_descriptor {any}", .{ block_descriptor });

			var buf: [4096]u8 = undefined;
			const block = buf[0..block_descriptor.block_size];
			_ = try reader.read(block);

			const end_magic = try reader.readIntLittle(Frame.LZ4.Magic);
			log.debug("end magic {x}", .{ end_magic });
			if (end_magic != Frame.LZ4.magic_end) return LZ4DecodeFrameError.BadEndMagic;

			log.debug("block {any}", .{ block });
			const res = if (!block_descriptor.uncompressed) try decodeBlock(dest, block) else block.len;
			log.debug("res {s}", .{ dest[0..res] });

			if (header.descriptor.content_checksum and builtin.mode == .Debug) {
				const expected_checksum = try reader.readIntLittle(u32);
				const actual_checksum = Hasher.hash(dest[0..res]);
				log.debug("{x} vs {x}", .{ expected_checksum, actual_checksum });
				std.debug.assert(expected_checksum == actual_checksum);
			}

			return res;
		}
	}
}

test "frame" {
	std.testing.log_level = .debug;
	const src = @embedFile("./testdata/small.txt.lz4");
	const expected = @embedFile("./testdata/small.txt");
	var dest: [expected.len]u8 = undefined;

	const decoded_size = try decodeFrame(&dest, src);

	try std.testing.expectEqual(@as(usize, expected.len), decoded_size);
	try std.testing.expectEqualSlices(u8, expected, dest[0..decoded_size]);
}
