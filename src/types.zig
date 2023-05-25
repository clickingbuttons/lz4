const std = @import("std");

pub const Frame = struct {
	pub const Kind = enum { lz4, skippable };

	pub const LZ4 = struct {
		pub const Magic = u32;
		pub const magic_start: Magic = 0x184D2204;
		pub const magic_end: Magic = 0x0;

		pub const Header = packed struct { // packed structs go least to most significant
			pub const Descriptor = packed struct {
				dict_id: bool,
				_reserved: bool,
				content_checksum: bool,
				content_size: bool,
				block_checksum: bool,
				block_independent: bool,
				version: u2,
				comptime {
					std.debug.assert(@sizeOf(@This()) == 1);
				}
			};
			pub const BlockDescriptor = packed struct {
				_reserved2: u4,
				block_maxsize: u3,
				_reserved1: bool,
				comptime {
					std.debug.assert(@sizeOf(@This()) == 1);
				}
			};

			descriptor: Descriptor,
			block_descriptor: BlockDescriptor,
			content_size: u64,
			dictionary_id: u32,
			checksum: u8,
			comptime {
				std.debug.assert(@sizeOf(@This()) == 16);
			}
		};

		// Optional content size (u64)
		// Optional dictionary id (u32)

		// Second byte of xxh32() using zero as a seed and full descriptor as input.
		pub const FrameDescriptorChecksum = u8;

		pub const DataBlock = packed struct {
			block_size: u31,
			uncompressed: bool,
			// block data
			// optional checksum (u32)
		};

		// end magic (u32)
		// Optional checksum (u32)
	};

	pub const Skippable = struct {
		pub const Header = packed struct {
			pub const magic_min = 0x184D2A50;
			pub const magic_max = 0x184D2A5F;

			magic_number: u32,
			frame_size: u32,
		};
	};
};
