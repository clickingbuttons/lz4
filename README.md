# lz4

Implementation of LZ4 decompression for
[block](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) and
[frame](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md) formats in Zig. Added reader
type makes decoding frame streams easy.

## Installation
`build.zig.zon`
```zig
.{
	.name = "yourProject",
	.version = "0.0.1",

	.dependencies = .{
		.lz4 = .{
			.url = "https://github.com/clickingbuttons/lz4/archive/refs/heads/master.tar.gz",
			.hash = "1220bd2264e4b165f37b32ae458ff7a1b64e47d426feaf4b8276cb8458b8161d8160",
		},
	},
}
```
`build.zig`
```zig
	const lz4 = b.dependency("lz4", .{
		.target = target,
		.optimize = optimize,
	});
	exe.addModule("lz4", lz4.module("lz4"));
```

## Usage

### Reader
You can wrap an existing reader using `decompressStream`.

```zig
const lz4 = @import("lz4");

const allocator = std.heap.page_allocator;
var file = try std.fs.cwd().openFile("file.lz4", .{});

var stream = lz4.decompressStream(allocator, file.reader());
defer stream.deinit();
var reader = stream.reader();

// The LZ4 format does not require including the uncompressed size. You can guess a large size or
// iterate until EOS.
var buf: []u8 = try allocator.alloc(u8, 1_000_000);
defer allocator.free(buf);
const res = try reader.read(buf);
std.debug.print("{s}", .{ buf[0..res] });
```

### Frame
```zig
const lz4 = @import("lz4");

const allocator = std.heap.page_allocator;
var file = try std.fs.cwd().openFile("frame.lz4", .{});

const decompressed = try lz4.decodeFrame(allocator, reader, true);
defer allocator.free(decompressed);
```

### Block
```zig
const lz4 = @import("lz4");

const allocator = std.heap.page_allocator;
const compressed = "\xf7\x12this is longer than 15 characters\x0b\x00";

const decoded = try lz4.decodeBlock(allocator, compressed);
defer allocator.free(decoded);
std.log.debug("{s}\n", .{ decoded }); // this is longer than 15 characters characters 
```
