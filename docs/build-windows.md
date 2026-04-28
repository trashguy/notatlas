# Building for Windows

Two supported paths:

1. **Cross-compile from Linux** (recommended for soak distribution): one
   build host produces an `.exe` for everyone, devs just run it.
2. **Native build on Windows**: each Windows dev box compiles locally.
   More setup per machine but lets devs iterate on engine code.

Both produce `zig-out/bin/notatlas-sandbox.exe`. The build.zig is identical;
the only difference is the host.

## Cross-compile from Linux

One-time setup on the Linux build host:

```sh
make setup-windows
```

Downloads `vulkan-1.lib` (Vulkan loader import library) into
`libs/windows/vulkan/lib/`. The script tries Silk.NET's NuGet package first,
then falls back to generating the import lib from Khronos's `vulkan-1.def`
via `zig dlltool`.

Build:

```sh
make build-windows         # ReleaseSafe
make build-windows-debug   # Debug
# or directly:
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

## Native build on Windows

Per-dev-box prereqs:

| Tool | Why | Get it |
|---|---|---|
| Zig 0.15.2 | Compiler / build driver | <https://ziglang.org/download/> |
| Vulkan SDK | Provides `glslc.exe` for shader compilation | <https://vulkan.lunarg.com/sdk/home> |
| Python 3 | One-time `vulkan-1.lib` import lib generation | <https://www.python.org/downloads/> or `winget install Python.Python.3` |

The Vulkan SDK installer puts `glslc.exe` on `PATH` automatically. Confirm
with `glslc --version` in a fresh shell.

One-time setup (from a clone):

```bat
python scripts\fetch_windows_deps.py
```

This generates `libs\windows\vulkan\lib\vulkan-1.lib` using `zig dlltool`.
You only need to do this once per clone.

Build:

```bat
zig build -Doptimize=ReleaseSafe
```

Or for debug:

```bat
zig build
```

Output lands at `zig-out\bin\notatlas-sandbox.exe`.

### Optional: GNU Make on Windows

The Makefile targets (`make build-windows`, `make setup-windows`) work on
a Windows host too — but you need both `make` and a POSIX-ish shell because
some recipes use `[ -f ... ]` syntax. Pick whichever you already use:

| Manager | Command | Notes |
|---|---|---|
| **winget** | `winget install ezwinports.make` | Official MS package manager, ships with Win10/11. Standalone make — combine with Git Bash for the shell. |
| **Scoop** | `scoop install make` | Popular among devs; user-scope, no admin. |
| **Chocolatey** | `choco install make` | Older, needs admin shell. |
| **MSYS2** | `pacman -S make` | Heaviest install but you also get bash + a real POSIX shell, which is what the Makefile actually wants. |

If you don't want to install any of the above, skip `make` entirely and
call `zig build -Dtarget=...` directly — the Makefile is just a convenience
shim over those commands. (NuGet is .NET-package-only; it doesn't ship
GNU make.)

## Running

The `.exe` dynamically links `vulkan-1.dll`. Modern AMD/Nvidia/Intel GPU
drivers ship it, but if the loader is missing, install the Vulkan Runtime
(also bundled in the SDK above).

That's the only runtime dependency — no MSVC redistributable, no separate
GLFW DLL (zglfw is statically linked).

## What's not in this build

- No server / NATS bits — the sandbox is the whole shipping artifact today.
- Hot-reload (the `inotify`-backed file watcher) is Linux-only by design;
  the Windows binary uses a no-op stub. Edit-save-iterate cycles work
  through a full rebuild.
