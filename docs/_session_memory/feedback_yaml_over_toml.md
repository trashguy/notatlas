---
name: notatlas uses YAML for config, not TOML
description: Project chose YAML 2026-04-27 over TOML and JSON for the data-driven config layer. Don't propose TOML for new configs.
type: feedback
originSessionId: 96c6efa1-f164-4d0f-8c5a-6881a8fa300c
---
For notatlas's data-driven config layer (waves, ships, biomes, recipes-config, tier_distances, etc.), the chosen format is **YAML**, parser is **`ymlz` (pwbh)**, schema is **YAML 1.2 only**.

**Parser history:** First tried `zig-yaml` (kubkon) — its main branch is on Zig 0.16-dev (`b.graph.io`), broke against 0.15.2. Latest tag (0.2.0) was 0.13-era. Switched to `ymlz` 0.6.0 — reflection-based, idiomatic, compiles clean on 0.15.2. If ymlz becomes a problem later, `devnw/zig/yaml` (gitlab) is the documented YAML 1.2.2 alternative; `gwagner/zig-yaml-parser` is unmaintained and needs system libyaml.

**Why:** User picked YAML after I walked through TOML/JSON/YAML tradeoffs. They prefer YAML's nested structure for the deeper configs (ship hulls, recipes) and multi-line strings for inline Lua. They accepted the type-coercion footgun in exchange.

**How to apply:**
- New config files use `.yaml`, not `.toml` or `.json`. Documented in `docs/05-data-model.md`.
- Quote anything in YAML that looks numeric/bool/null-shaped (`dir: "no"` not `dir: no`) — the doc has the safety practice.
- If a future task tempts a TOML proposal "for safety reasons", don't relitigate — the user heard the case and chose YAML.
- JSON is still allowed for external-tool interop (e.g. ServerGridEditor cell layout). Lua is still the answer for anything with logic.
