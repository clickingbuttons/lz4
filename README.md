# lz4

Implementation of LZ4 decompression for
[block](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) and
[frame](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md) formats in Zig. Added reader
type makes decoding streams easy.

## Installation

`build.zig.zon`
```zig
.{
    .name = "yourProject",
    .version = "0.0.1",

    .dependencies = .{
        .lz4 = .{
            .url = "https://github.com/clickingbuttons/lz4/archive/refs/heads/master.tar.gz",
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

Run `zig build` and then copy the expected hash into `build.zig.zon`.

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

### Block

A [LZ4 block](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) contains its size, data, then a negative offset to the match.

```zig
const lz4 = @import("lz4");

const allocator = std.heap.page_allocator;
const compressed = "\xf7\x12this is longer than 15 characters\x0b\x00";

const decoded = try lz4.decodeBlock(allocator, compressed);
defer allocator.free(decoded);
std.log.debug("{s}\n", .{ decoded }); // this is longer than 15 characters characters
```

### Frame

A [LZ4 frame](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md) contains magic, a frame descriptor, data blocks (which may have checksums), and an optional content checksum. They can be created using the `lz4` command.

```zig
const lz4 = @import("lz4");

const allocator = std.heap.page_allocator;
var file = try std.fs.cwd().openFile("frame.lz4", .{});

const decompressed = try lz4.decodeFrame(allocator, reader, true);
defer allocator.free(decompressed);
```

