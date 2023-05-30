.PHONY: fmt
fmt:
	find src -name "*.zig" -exec zig fmt {} \;
	zig fmt build.zig
