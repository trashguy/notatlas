.PHONY: all build run test release fmt fmt-check clean help \
        setup-windows build-windows build-windows-debug

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

# -----------------------------------------------------------------------------
# Windows builds (cross-compile from Linux, or native on a Windows host).
# Recipes use `python` rather than `python3` so they work on both Arch and
# stock Windows Python installs. The build.zig itself prints a friendly
# error if vulkan-1.lib is missing — no separate dep-check recipe needed.
# -----------------------------------------------------------------------------

setup-windows:
	@python scripts/fetch_windows_deps.py

build-windows:
	zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

build-windows-debug:
	zig build -Dtarget=x86_64-windows

help:
	@echo "make build               — debug build"
	@echo "make run                 — debug build + run sandbox"
	@echo "make test                — run unit tests"
	@echo "make release             — ReleaseFast build"
	@echo "make fmt                 — format all sources"
	@echo "make fmt-check           — verify formatting (non-zero on diff)"
	@echo "make clean               — remove zig-out and .zig-cache"
	@echo "make setup-windows       — download vulkan-1.lib for Windows cross-compile"
	@echo "make build-windows       — cross-compile sandbox.exe (ReleaseSafe)"
	@echo "make build-windows-debug — cross-compile sandbox.exe (Debug)"
