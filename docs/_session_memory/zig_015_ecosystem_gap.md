---
name: Zig 0.15.2 ecosystem-gap pattern
description: User is intentionally on Zig 0.15.2 until 0.16's libs catch up. Many popular Zig packages have moved their main branch to 0.16-dev and have no 0.15-tagged release. Expect this friction recurring; pattern for handling it.
type: project
originSessionId: 96c6efa1-f164-4d0f-8c5a-6881a8fa300c
---
**Fact:** notatlas (and `~/Projects/fallen-runes` after its bump) targets **Zig 0.15.2**. User stated reason: "until 16 has all its libs catch up." So we are on the *previous* stable while ecosystem is migrating to 0.16-dev.

**Why it matters:** Many popular Zig packages now have unstable main branches that target 0.16-dev (using e.g. `b.graph.io`, the new `std.Io.Reader`, etc.) and don't have current 0.15-compatible tagged releases. Examples encountered: `kubkon/zig-yaml` (latest tag 0.2.0 from 0.13 era; HEAD on 0.16). Expect this to bite again with `zphysics`/Jolt bindings, glTF loaders, vulkan bindings, and other zig-gamedev libs.

**How to apply when adding any new Zig dep:**
1. Check the dep's latest tag *and* compare against `b.graph.io` / `std.Io` usage in its build.zig and source. If main is on 0.16-dev with no 0.15 tag, expect it to fail.
2. Try `zig fetch --save` and `zig build test` early — find out fast.
3. If it breaks, in priority order:
   - Find a working tag or commit before the 0.16 migration (bisect).
   - Switch to a peer parser/library that's still 0.15-compatible (search the ecosystem; pwbh, devnw, etc. often have alternatives).
   - Vendor + patch (last resort; starts a fork).
   - Defer the dep until either it ships a 0.15 release or notatlas moves to 0.16.
4. Don't relitigate the version pin — the user picked 0.15.2 deliberately.

**Reference:** see `feedback_yaml_over_toml.md` for the worked example (ymlz won out over zig-yaml).
