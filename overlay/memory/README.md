# nugget memory

Durable cross-session memory for the Rockie nugget overlay. Plain text, no
database — the design (`designs/nugget-parity-overlay-2026-06-20.md`, Slice D)
deliberately does **not** port the SQLite/FTS5 stack; Goose's builtin memory
extension reads this directory and is the idiomatic, config-only substitute.

The installer copies this scaffold to the Goose memory dir
(`$XDG_CONFIG_HOME/goose/memory/`, default `~/.config/goose/memory/`). At
runtime:

- The agent emits `[LEARN]` / `[DEAD-END]` blocks in its replies (see the
  ethos in `.goosehints`).
- The `Stop` hook (`hooks/capture.sh`) appends them here, deduped:
  - `learning.txt`  — durable rules and gotchas (category `learning`;
    cross-project improvements tagged `harness-upstream`).
  - `dead-end.txt`  — research directions proven dead.
- Next session, Goose's memory extension surfaces them via `retrieve_memories`.

Entry format is the Goose memory category-file convention: a `# <tags>` line
followed by the entry, blocks separated by a blank line. Edit by hand freely;
the hook only appends and never rewrites existing entries.
