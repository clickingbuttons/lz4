// Spec (not great): https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
//
// match_len: u4
// literal_len: u4
// extended_literal_len (if literal_len == 15): [*]u8
// literal: [literal_len]u8
// match_offset: u16 (negative lookbehind from last literal) (CAN REFERENCE PREVIOUS BLOCKS!!)
// extended_match_len (if match_len == 15): [*]u8 
//
// Blocks repeat until end of EOS. Last block is allowed to have only literals.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.lz4_block);
pub const DecodeError = error {
	BadMatchOffset,
	BadMatchLen,
	PrematureEnd,
};

pub const Token = packed struct { // packed structs go least to most significant
	match_len: u4,
	literal_len: u4,
};
pub const Offset = u16;

inline fn readLength(len: u4, reader: anytype) !usize {
	if (len != 15) {
		return len;
	}
	var res: usize = len;

	var last_read: u8 = try reader.readByte();
	// TODO: best way to handle overflow?
	res += last_read;
	while (last_read == 255) {
		last_read = try reader.readByte();
		res += last_read;
	}

	return res;
}

fn testReadLength(len: u4, src: []const u8) !usize {
	var reader = std.io.fixedBufferStream(src);
	return readLength(len, reader.reader());
}

test "extended length" {
	try std.testing.expectEqual(@as(usize, 0), try testReadLength(0, &[_]u8{}));
	try std.testing.expectEqual(@as(usize, 48), try testReadLength(15, &[_]u8{ 33 }));
	try std.testing.expectEqual(@as(usize, 280), try testReadLength(15, &[_]u8{ 255, 10 }));
	try std.testing.expectEqual(@as(usize, 15), try testReadLength(15, &[_]u8{ 0 }));
}

inline fn wildMemcpy(dest: []u8, src: []u8) void {
	// Needed because @memcpy cannot alias.
	std.debug.assert(dest.len == src.len);
	for (0..src.len) |i| {
		dest[i] = src[i];
	}
}

fn decodeBlockStream(dest: *std.ArrayList(u8), reader: anytype) !void {
	const token = try reader.readStruct(Token);
	log.debug("token {any}", .{ token });

	var literal_len = try readLength(token.literal_len, reader);
	log.debug("literal len {d}", .{ literal_len });
	const old_len = dest.items.len;
	try dest.resize(old_len + literal_len);

	// Read literals into destination buffer.
	var literals = dest.items[old_len..dest.items.len];
	const n_read = try reader.read(literals);
	if (literal_len != n_read) {
		log.err("premature stream end. expected {d} literals but got {d}", .{ literal_len, n_read });
		return DecodeError.PrematureEnd;
	}

	// Read match offset and check for EOF
	const match_offset = reader.readIntLittle(Offset) catch |err| {
		if (err == error.EndOfStream) return;
		return err;
	};
	log.debug("match_offset {d}", .{ match_offset });

	// Check match offset is in dest buffer
	const abs_offset = if (std.math.sub(usize, dest.items.len, match_offset)) |res|
		res
	else |_| {
		log.err("match_offset {d} points to {d} bytes before buffer start",
			.{ match_offset, @intCast(i64, dest.items.len) - @intCast(i64, match_offset) });
		return DecodeError.BadMatchOffset;
	};

	// Append match to destination buffer
	const len = 4 + try readLength(token.match_len, reader);
	const old_len2 = dest.items.len;
	try dest.resize(old_len2 + len);
	if (abs_offset + len > dest.items.len) {
	 	log.err(
			"match references bytes {d}..{d} which are after dest size {d}",
			.{ abs_offset, abs_offset + len, dest.items.len });
	 	return DecodeError.BadMatchLen;
	}

	wildMemcpy(dest.items[old_len2..old_len2 + len], dest.items[abs_offset..abs_offset + len]);
}

pub fn decodeBlock(allocator: Allocator, src: []const u8) ![]u8 {
	var stream = std.io.fixedBufferStream(src);
	var reader = stream.reader();

	var dest = std.ArrayList(u8).init(allocator);

	while (reader.context.pos < src.len) {
		try decodeBlockStream(&dest, reader);
	}

	return dest.toOwnedSlice();
}

fn testBlock(compressed: []const u8, comptime expected: []const u8) !void {
	// var dest: [expected.len * 2]u8 = undefined;
	// var allocator = std.heap.FixedBufferAllocator.init(dest);
	var allocator = std.testing.allocator;

	const decoded = try decodeBlock(allocator, compressed);
	defer allocator.free(decoded);

	try std.testing.expectEqualSlices(u8, expected, decoded);
}

test "no compression" {
	// echo "asdf" | lz4 -c -i | hexdump -C
	try testBlock("\x40asdf", "asdf");
	try testBlock("\xf0\x00012345678945678", "012345678945678");
}

test "small compression" {
	// Go back 6 and copy (4 + 1) bytes
	try testBlock("\x61hello \x06\x00", "hello hello");

	// Go back 6 and copy (4 + 1) bytes
	try testBlock("\xa10123456789\x06\x00", "012345678945678");
}

test "empty" {
	try testBlock("\x05\x5d", "");
}

test "medium compression" {
	// Go back 11 and copy (4 + 8) bytes
	try testBlock(
		"\xf7\x12this is longer than 15 characters\x0b\x00",
		"this is longer than 15 characters characters",
	);
}

test "multiple blocks" {
	// Go back 6 and copy (4 + 3) bytes
	try testBlock(
		"\xb3Hello there\x06\x00\xf0\x12I am a sentence to be compressed.",
		"Hello there there I am a sentence to be compressed."
	);

	// Go back 6 and copy (4 + 3) bytes
	// Go back 17 and copy 18 bytes.
	try testBlock(
		"\xb3Hello there\x06\x00\xf8\x11I am a sentence to be compressed\x11\x00\x50essed",
		"Hello there there I am a sentence to be compressed to be compressed"
	);

	const compressed = "\xf2\x57Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod\n" 
		++ "tempor incididunt ut labore et[\x00\xf2;e magna aliqua. Ut enim ad minim\n" 
		++ "veniam, quis nostrud exercitation ullamcoZ\x00\x00%\x00bisi utS\x00\xf2\x01ip ex ea\n" 
		++ "commodo\xc1\x00pquat. DS\x00\xa2aute irure\x91\x00\xf0\x02 in reprehenderit\x11\x00\xb0voluptate\n" 
		++ "v\xea\x00\xa4 esse cill\"\x01\xf0\x15e eu fugiat nulla pariatur. ExcepteuG\x01\xf0\x04nt occaecat\n" 
		++ "cupidat2\x00\xa0on proidenF\x01\x00*\x01\x80in culpa\xf8\x00\xe0 officia deser\x1e\x00@moll\x93\x01\x00*\x01bid\n" 
		++ "est\xfe\x00\x80um.\n" 
		++ "\n" 
		++ "Sed\xff\x00Ppersp7\x00\xf3\x0etis unde omnis iste natus err\xdd\x01\x05\xe1\x00\xe1m accusantium\n" 
		++ "\xfe\x01\xa2emque laud\x16\x00\xf1\x01, totam rem aper\x9f\x01 ea%\x000ips\xb2\x00\xf0\x04ae ab illo inventor:\x01\x11r\xb2\x01\xf0\x10s et quasi architecto beatae vi\x06\x00Rdicta\x08\x01\xf1\x00explicabo. Nemo\x1d\x02\x10\n" 
		++ "g\x00\x18m\xb4\x00Dquia\x10\x00\x12s\xae\x02@sper\xe6\x00\x80r aut od/\x01!ut\xa4\x01\x00d\x01 edZ\x01\x00\x17\x02\x01\x0f\x02 un*\x00\x00\x8b\x02\x12i\x07\x02`es eos$\x00! rg\x02\x14e`\x00\x00$\x01\x003\x00\xa0i nesciunt\x9b\x00\x90que\n" 
		++ "porro3\x00\x91squam est\xb7\x02\x03Q\x00\x04R\x03\x01\xac\x00\x01Y\x01\x02\xa9\x00\x0cW\x03$,\n" 
		++ "X\x03\x11 m\x02\x02W\x03\x016\x00rnon num^\x00\x92ius modi g\x03\x12ah\x03\x00\x1e\x02\x05f\x03\x1b\n" 
		++ "f\x03\x12m\x14\x03 am\x80\x018era\xf8\x01\x0e{\x03(a |\x03\x12\n" 
		++ "|\x03\x19m|\x03\"em~\x03Q corp}\x03ssuscipi\x90\x02kiosam,\x92\x03!d\n" 
		++ "\x92\x03\x12 \x92\x03\x16i\x92\x03Tur? Q\x94\x03\x10m\xfe\x00` eum i\x9c\x03\n" 
		++ "\x93\x03\x00~\x01 in\xd7\x03\x05\x9a\x03\x00/\x00\x04\x9a\x03\x01\xe3\x00\xf8\x00nihil molestiaeg\x00\x10,-\x00\x00\xa0\x02\x10u\n" 
		++ "\x01\x14i\xe7\x02\x01n\x00\x03\xc5\x034quo\xf1\x01\x18s\xd2\x03Ptur?\n";
	const expected = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod\n" 
		++ "tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim\n" 
		++ "veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea\n" 
		++ "commodo consequat. Duis aute irure dolor in reprehenderit in voluptate\n" 
		++ "velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat\n" 
		++ "cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id\n" 
		++ "est laborum.\n" 
		++ "\n" 
		++ "Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium\n" 
		++ "doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore\n" 
		++ "veritatis et quasi architecto beatae vitae dicta sunt explicabo. Nemo enim\n" 
		++ "ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia\n" 
		++ "consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt. Neque\n" 
		++ "porro quisquam est, qui dolorem ipsum quia dolor sit amet, consectetur,\n" 
		++ "adipisci velit, sed quia non numquam eius modi tempora incidunt ut labore\n" 
		++ "et dolore magnam aliquam quaerat voluptatem. Ut enim ad minima veniam, quis\n" 
		++ "nostrum exercitationem ullam corporis suscipit laboriosam, nisi ut aliquid\n" 
		++ "ex ea commodi consequatur? Quis autem vel eum iure reprehenderit qui in ea\n" 
		++ "voluptate velit esse quam nihil molestiae consequatur, vel illum qui\n" 
		++ "dolorem eum fugiat quo voluptas nulla pariatur?\n";
	try testBlock(compressed, expected);
}

// test "garbage input" {
// 	var dest: [4096]u8 = undefined;
// 	try std.testing.expectError(expected, decodeBlock(&dest, "Hello there"));
// }
// 
// test "small buffer" {
// 	var dest: [4]u8 = undefined;
// 	try std.testing.expectError(DecodeError.SmallDest, decodeBlock(&dest, "this is longer than 4"));
// }
// 
// test "input ends prematurely" {
// 	const compressed = "\x90Not 9";
// 	var dest: [10]u8 = undefined; // Oversized because we check for len 9
// 
// 	try std.testing.expectError(DecodeError.PrematureEnd, decodeBlock(&dest, compressed));
// }
