ZIG ?= zig

.PHONY: build test release clean

build:
	$(ZIG) build

test:
	$(ZIG) build test

release:
	$(ZIG) build -Doptimize=ReleaseSmall

clean:
	rm -rf .zig-cache zig-out release
