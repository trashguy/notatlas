.PHONY: all build run test release fmt fmt-check clean help \
        setup-windows check-windows-deps build-windows build-windows-debug

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
# Windows cross-compilation (from Linux)
# -----------------------------------------------------------------------------

setup-windows:
	@python3 scripts/fetch_windows_deps.py

check-windows-deps:
	@if [ ! -f "libs/windows/vulkan/lib/vulkan-1.lib" ]; then \
		echo "Missing libs/windows/vulkan/lib/vulkan-1.lib"; \
		echo "Run: make setup-windows"; \
		exit 1; \
	fi

build-windows: check-windows-deps
	zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

build-windows-debug: check-windows-deps
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
