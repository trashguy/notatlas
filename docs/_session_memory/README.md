# Session memory snapshot — TEMPORARY

This directory is a one-time copy of the auto-memory system from the
primary dev machine, committed to the repo so a different machine
(travel laptop) can pick up session context with continuity.

**Source path on the primary machine:**
`~/.claude/projects/-home-trashguy-Projects-notatlas/memory/`

## On the travel laptop

When you start a Claude Code session in this repo, manually share
the relevant context by either:

1. **Pointing Claude at this directory** — paste the contents of
   `MEMORY.md` (the index) plus any specific entry that's relevant
   to what you're working on. Claude won't auto-load these files
   like it would the real memory system, but it will read them when
   asked.

2. **Mirroring back to the local memory path:**
   ```bash
   mkdir -p ~/.claude/projects/-home-trashguy-Projects-notatlas/memory
   cp docs/_session_memory/*.md \
      ~/.claude/projects/-home-trashguy-Projects-notatlas/memory/
   ```
   This makes auto-memory work like it does on the primary box.

## When you get home

Delete this directory:

```bash
rm -rf docs/_session_memory
git add -A docs/_session_memory
git commit -m "chore: remove temporary session memory snapshot"
git push
```

The files in here will already exist (and may have been updated)
in the home machine's actual memory directory — the git delete
removes the temp copy without touching the real one.

## Read-first

- `current_work.md` — the active pickup pointer; **read this first**
- `MEMORY.md` — the index of all entries with one-line hooks

## Snapshot taken

2026-05-01, before flight to London. Latest commit: `1f1d796`
(persistence-writer cleanup). Next session expected to pick up the
SLA arc — see `current_work.md` for the 4-commit plan.
