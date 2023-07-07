pub const block = @import("./decode/block.zig");
pub const frame = @import("./decode/frame.zig");
const decompress = @import("./decompress.zig");

/// Returns a struct that implements a Reader interface for a stream of LZ4 frames.
pub const decompressStream = decompress.decompressStream;

test {
    _ = @import("./decode/block.zig");
    _ = @import("./decode/frame.zig");
    _ = @import("./decompress.zig");
}
