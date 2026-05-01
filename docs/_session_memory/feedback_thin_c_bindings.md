---
name: prefer thin C-API bindings over Zig wrapper packages
description: When pulling in a C/C++ library, write thin Zig FFI bindings against the library's C API directly rather than depending on an existing Zig wrapper module
type: feedback
originSessionId: ab1fdfa8-8749-49fe-880e-7aebeda96444
---
When a C/C++ library is needed (Jolt, future: Vulkan extensions, audio, etc.), prefer **writing thin bindings against the library's C API ourselves** over depending on an existing Zig wrapper package.

**Why:** Established pattern across this user's Zig projects since adopting Zig. Reasons that compound:
- Zig 0.15→0.16 ecosystem churn (`zig_015_ecosystem_gap`) — wrapper packages frequently target 0.16-dev with no 0.15 tag.
- Wrapper packages bring their own build-system conventions (zig-gamedev's are notable) that conflict with our pinned-glibc/cross-compile setup (`build_zig_glibc_pin`).
- Thin bindings keep the FFI surface small — only what we actually call — and the C API is what the library vendor commits to ABI-wise; Zig wrappers can bit-rot or remove APIs without notice.
- Easier to reason about lifetime / ownership when the binding is in our tree.

**How to apply:**
- Default: vendor or git-submodule the C/C++ lib, build it with our `build.zig`, expose only the `extern fn` declarations we need on the Zig side, then layer idiomatic Zig structs/methods on top in our own files.
- For C++ libs that don't ship a C API (rare), prefer writing a small `c_api.cpp` wrapper in our tree over pulling a third-party Zig binding.
- Don't auto-translate massive headers with `@cImport` — handwrite the small subset of `extern fn`s we use; clearer call sites and faster compile.
- Concrete instance: M3 Jolt integration — bind against JoltC (the official C API), not zphysics or other Zig wrappers.
