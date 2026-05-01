# Third-Party Licenses

notatlas embeds and links against the following third-party software.
Each entry lists the upstream name, version pin, source URL, license,
and where the license text lives in this tree.

## Vendored under `vendor/`

These dependencies are vendored as source trees in `vendor/<name>/` and
built directly by `build.zig`. License files are kept inside each
upstream tree.

| Project | Version | License | License file in tree | Upstream source |
|---|---|---|---|---|
| Jolt Physics | v5.5.0 | MIT | `vendor/JoltPhysics/LICENSE` | https://github.com/jrouwe/JoltPhysics |
| Lua | 5.4.8 | MIT | `vendor/lua/src/lua.h` (terminal copyright block) | https://www.lua.org/ftp/lua-5.4.8.tar.gz |

Provenance for each (version, SHA256 of the upstream tarball, build
defines) lives in `vendor/<name>/PROVENANCE.md` where applicable.

## Fetched via `build.zig.zon`

These are resolved by Zig's package manager into `zig-pkg/` and have
their own license files there.

| Project | Pin | License | Upstream source |
|---|---|---|---|
| zglfw (GLFW Zig wrapper) | 0.10.0-dev | Zlib / MIT (GLFW + wrapper) | https://github.com/zig-gamedev/zglfw |
| system_sdk | 0.3.0-dev | various (system SDKs aggregator) | https://github.com/zig-gamedev/system_sdk |
| ymlz (YAML loader) | 0.5.0 | MIT | https://github.com/pwbh/ymlz |
| vulkan-headers | (per zon) | Apache-2.0 / MIT | https://github.com/KhronosGroup/Vulkan-Headers |
| nats-zig | sibling project | MIT | `~/Projects/nats-zig` (in-house) |

License files for the Zig-pkg-resolved deps are at
`zig-pkg/<hash>/LICENSE` after a build.

## Local-machine system libraries

Linked at runtime / link time but not vendored in this repository:

| Library | License | Notes |
|---|---|---|
| Vulkan loader (`libvulkan`) | Apache-2.0 | Linux: system `/usr/lib/libvulkan.so`. Windows: `libs/windows/vulkan/vulkan-1.lib` (fetched by `make setup-windows`). |
| glibc | LGPL-2.1+ | Linux host; Zig pins glibc 2.38 to sidestep a 0.15.2 LLD/SFrame bug on Arch (see `build.zig` top comment + memory `build_zig_glibc_pin.md`). |

## Adding a new dependency

When adding a new vendored or fetched dep:

1. Drop it under `vendor/<name>/` (vendored) or add to `build.zig.zon` (fetched).
2. Add a row to the table above with version, license, and source URL.
3. For vendored deps with a license file in the upstream tree, leave
   the upstream `LICENSE` (or equivalent) file in place and reference
   it here.
4. For vendored deps where the license is embedded in headers (Lua's
   case), reference the file containing the copyright block.
5. Update `vendor/<name>/PROVENANCE.md` with the upstream URL, version
   tag or release date, and SHA256 of the source tarball if applicable.
