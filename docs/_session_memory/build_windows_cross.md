---
name: Windows build setup
description: How notatlas builds for Windows — both Linux→Windows cross-compile and native Windows. Covers the three non-obvious gotchas (Jolt SIMD CPU features, Linux-only file_watch, Linux-host-only glibc pin).
type: project
originSessionId: 4d81ae89-b553-4067-b823-ddb48973dde6
---
Two supported paths: cross-compile from a Linux host, or native build on a Windows dev box. Same `build.zig`, same artifact (`zig-out/bin/notatlas-sandbox.exe`).

- `make setup-windows` runs `scripts/fetch_windows_deps.py` to drop `vulkan-1.lib` (import lib generated from Khronos's `vulkan-1.def` via `zig dlltool` since Silk.NET NuGet ships only DLLs) into `libs/windows/vulkan/lib/`. Gitignored. Works on either OS.
- Cross-compile: `make build-windows` → `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`.
- Native Windows: `python scripts\fetch_windows_deps.py` then `zig build -Doptimize=ReleaseSafe`. Needs Zig 0.15.2 + Vulkan SDK (for glslc) + Python 3.
- Output runtime needs `vulkan-1.dll` from GPU driver or Vulkan Runtime.
- Doc for devs: `docs/build-windows.md`.

**Why:** devs need to soak-test on Windows boxes; mirroring fallen-runes' approach so we don't duplicate decisions. Cross-compile is the default distribution path; native-Windows is for devs who modify engine code locally.

**How to apply:** when adding code that touches OS-specific APIs, gate by `builtin.os.tag` and provide a no-op stub for non-Linux. When linking new system libs, switch on `is_windows` in build.zig (see vulkan vs vulkan-1 split).

## Three gotchas that bit during the port

1. **Jolt + Zig cross-compile = baseline CPU.** Zig defaults `-mcpu=baseline` for any non-native target (SSE2 only). Jolt's `_mm_addsub_ps` etc. need SSE3+. The `-mavx2`/`-msse4` cflags update preprocessor macros but not LLVM's codegen target — fix is `joltTarget()` helper in build.zig that adds the SIMD features (sse3..avx2, bmi/bmi2, lzcnt, popcnt, f16c, fma) to the resolved target query. Native Linux didn't hit this because `mcpu=native` already covers it.
2. **`fd_t` differs per OS.** Windows `posix.fd_t = *anyopaque`, Linux is `i32`. inotify watcher in `src/render/file_watch.zig` only compiles on Linux — wrapped in `Watcher = if (builtin.os.tag == .linux) LinuxWatcher else StubWatcher`. Hot-reload is dev-only; soak builds don't need it.
3. **glibc pin is Linux-host-only.** `default_target` pins glibc 2.38 (Arch LLD/SFrame workaround). On a Windows host that field is meaningless and would break native `zig build`. Gate the pin behind `builtin.os.tag == .linux` (build-host check, not target-arch) so non-Linux hosts get an empty default_target.
