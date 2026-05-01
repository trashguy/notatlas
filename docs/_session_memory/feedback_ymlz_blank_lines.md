---
name: ymlz panics on blank lines
description: pwbh's ymlz YAML parser panics on blank lines and on fixed-size arrays — workarounds for any new YAML config in notatlas
type: feedback
originSessionId: 0e70b569-17de-45d1-95e3-329e743019b1
---
ymlz (the YAML parser used in notatlas, see `feedback_yaml_over_toml.md`)
has two non-obvious limitations. Both are worth remembering before adding
or hand-editing any YAML in `data/`:

1. **Blank lines panic.** `getFieldName` slices `raw_line[indent..]` and
   asks the field-resolver to find a struct field with that name; on a
   blank line it tries to match `""` and panics with "No such field in
   given yml file." Comment lines (`#`) are fine; truly empty lines are
   not. Keep YAML files flush with no blank separators.

2. **Fixed-size arrays unsupported.** A `[3]f32` or `[2]f32` field can't
   be parsed from `[r, g, b]` syntax. Use a struct of named scalars
   instead — `direction: { x, z }` for the wave loader,
   `shallow_color: { r, g, b }` for the ocean loader.

**Why:** Discovered during M2.5 (2026-04-27) — the `data/ocean.yaml` work
hit both issues; the first cost a test-run debugging cycle, the second
was anticipated from the existing wave loader.

**How to apply:** When writing a new `data/*.yaml`, mirror the wave/ocean
loader pattern — block-style nested structs of named scalars, no blank
lines. Document the constraint at the top of the YAML file so a human
editor doesn't reintroduce blanks for "readability".
