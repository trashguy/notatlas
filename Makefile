.PHONY: all build run test release fmt fmt-check clean help

all: build

build:
	zig build

run:
	zig build run

test:
	zig build test

release:
	zig build -Doptimize=ReleaseFast

fmt:
	zig fmt build.zig src

fmt-check:
	zig fmt --check build.zig src

clean:
	rm -rf zig-out .zig-cache

help:
	@echo "make build      — debug build"
	@echo "make run        — debug build + run sandbox"
	@echo "make test       — run unit tests"
	@echo "make release    — ReleaseFast build"
	@echo "make fmt        — format all sources"
	@echo "make fmt-check  — verify formatting (non-zero on diff)"
	@echo "make clean      — remove zig-out and .zig-cache"
