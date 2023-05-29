# lz4

Implementation of LZ4 decompression for
[block](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) and
[frame](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md) formats in Zig. Added reader
type makes decoding frame streams easy.

## Usage

### Reader
You can wrap an existing reader using `decompressStream`.

```zig
const lz4 = @import("lz4/lib.zig");

const allocator = std.heap.page_allocator;
var file = try std.fs.cwd().openFile("file.lz4", .{});

var stream = lz4.decompressStream(allocator, file.reader());
defer stream.deinit();
var reader = stream.reader();

// The LZ4 format does not require including the uncompressed size. You can guess a large size or
// iterate until EOS.
var buf: []u8 = try allocator.alloc(u8, 1_000_000);
defer allocator.free(buf);
const res = try lz4reader.read(buf);
```

### Frame
```zig
const allocator = std.heap.page_allocator;
var file = try std.fs.cwd().openFile("file.lz4", .{});

const decompressed = try decodeFrame(allocator, reader, true);
```

### Block
```zig
const allocator = std.heap.page_allocator;
const compressed = "\xf7\x12this is longer than 15 characters\x0b\x00";

const decoded = try decodeBlock(allocator, compressed);
defer allocator.free(decoded);
std.log.debug("{s}\n", .{ decoded }); // this is longer than 15 characters characters 
```
