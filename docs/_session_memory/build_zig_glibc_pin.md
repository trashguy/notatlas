---
name: pin glibc_version on linux-gnu native targets
description: Workaround for Zig 0.15.2 + Arch glibc-2.41 SFrame relocation bug; build.zig pins glibc 2.38 so Zig builds its bundled crt1.o.
type: project
originSessionId: 9014770d-bef4-482b-9b2d-e54d460b2ec1
---
On native linux-gnu targets, `build.zig` pins `glibc_version = 2.38.0`
via `b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu,
.glibc_version = ... } })`.

**Why:** Zig 0.15.2's bundled LLD (and its self-hosted linker, via
`-fno-lld`) can't handle the `R_X86_64_PC64` SFrame relocations in
Arch's `Scrt1.o` (binutils 2.46 / glibc 2.41 era). Any libc-linked
Zig executable fails to link with:

> error: fatal linker error: unhandled relocation type R_X86_64_PC64
>   at offset 0x1c
>   note: in /usr/lib/.../crt1.o:.sframe

Pinning a glibc version flips Zig into "cross-compile" mode where it
builds its own crt1.o from `/usr/lib/zig/libc/glibc/csu` source — which
has no `.sframe` section.

**Side effect:** in cross-compile mode Zig stops searching system
library paths, so `build.zig` adds `/usr/lib` back via
`addLibraryPath(.{ .cwd_relative = "/usr/lib" })` for `libvulkan` /
`libX11` resolution. zglfw bundles its own X11 headers via `system_sdk`
so no header-path fixup is needed.

**How to apply:**
- If the SFrame error reappears after a Zig upgrade, **try removing the
  glibc pin first** — newer Zig LLD may handle SFrame natively. Run a
  one-liner test: `echo 'pub fn main() void {}' | zig build-exe -lc -`
  on a temp file.
- If installing `mold` (`sudo pacman -S mold`) becomes acceptable, that
  also resolves the bug — mold handles SFrame correctly. But Zig 0.15
  has no flag to point at a specific external linker, so even with mold
  installed the workaround stays in build.zig until Zig exposes one.
- The pin is harmless on other distros — 2.38 is widely supported and
  Zig will use system glibc when available at runtime.

Tracking issue (search if you need updates): "ziglang/zig" + "SFrame".
