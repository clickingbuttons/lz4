const block = @import("./decode/block.zig");
const frame = @import("./decode/frame.zig");
const decompress = @import("./decompress.zig");

pub const decompressStream = decompress.decompressStream;
pub const decompressStreamOptions = decompress.decompressStreamOptions;

pub const decodeFrame = frame.decodeFrame;
pub const decodeBlock = block.decodeBlock;
pub const decodeBlockArrayList = block.decodeBlockArrayList;

test {
	_ = @import("./decode/block.zig");
	_ = @import("./decode/frame.zig");
	_ = @import("./decompress.zig");
}
