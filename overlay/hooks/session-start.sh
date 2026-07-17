#!/usr/bin/env bash
# nugget SessionStart hook — installed-skills inventory (config-only, no SQLite).
#
# Fixes the documented failure mode: a session pulls one or more skills into
# ./skills/ via the find-skills recipe (overlay/recipes/find-skills.yaml), but
# once that turn scrolls out of context, nothing re-reminds the agent they're
# there — it stops reading them unless a skill happens to get mentioned again.
#
# Goose's Open-Plugins hook set (verified against goose 1.38 — see install.sh)
# documents SessionStart/SessionEnd/Stop/UserPromptSubmit/PreToolUse/
# PostToolUse. As of this writing it does NOT document a PreCompact/PostCompact
# event, or a `compact` matcher on SessionStart the way Claude Code and Codex
# expose (both sibling rockie-claude/rockie-codex harnesses get post-compaction
# re-injection for free because their SessionStart hook has no matcher and
# fires on every source their CLI emits, compact included). This hook covers
# "fresh session start" cleanly; it does NOT re-fire mid-session after an
# in-session compaction/summarization, because Goose gives plugins no signal
# that one happened. Tracked in
# https://github.com/Rockielab/rockie-nugget/issues/24 — revisit once Goose
# exposes a PreCompact/PostCompact event or a `compact` SessionStart matcher.
#
# Goose hooks are advisory (non-blocking) — this one only emits context, never
# gates a tool. stdout JSON with hookSpecificOutput.additionalContext is added
# as extra developer context for the session (the same Open-Plugins contract
# rockie-claude/rockie-codex use for their own SessionStart hooks).
#
# Fail-open: any error exits 0 so a broken hook never blocks a session.
set +e

INPUT="$(cat 2>/dev/null)"
WORKING_DIR="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("working_dir","") or "")
except Exception: print("")' 2>/dev/null)"
[ -z "$WORKING_DIR" ] && WORKING_DIR="$PWD"

REPORT_TXT=$(WORKING_DIR="$WORKING_DIR" python3 <<'PY'
import os
import pathlib
import re

SKILLS_LIST_CAP = 40
workspace = pathlib.Path(os.environ.get("WORKING_DIR", "."))
# find-skills.yaml pulls into a workspace-relative ./skills/ (read_file's
# sandbox rejects anything outside the workspace, so that's the only place a
# pulled skill can actually land) — not .agents/skills or .claude/skills.
skills_dir = workspace / "skills"


def parse_skill_md(skill_md: pathlib.Path) -> tuple[str, str]:
    """Extract (name, description) from a SKILL.md.

    Prefers YAML frontmatter's name:/description: fields. Falls back to
    the directory name and the first non-empty prose line in the body
    when frontmatter is missing, unparseable, or lacks one of the two
    fields. Lenient about the closing `---` fence: reads key: value
    lines right after the opening fence for as long as they look like
    frontmatter, then treats whatever follows as body — whether or not
    a proper closing fence was ever written — so a truncated frontmatter
    block still surfaces its fields instead of leaking a raw YAML line
    as the "description".
    """
    try:
        text = skill_md.read_text()
    except OSError:
        return skill_md.parent.name, "(SKILL.md unreadable)"

    lines = text.splitlines()
    fm_lines: list[str] = []
    body_start = 0
    if lines and lines[0].strip() == "---":
        i = 1
        while i < len(lines) and re.match(r"^[A-Za-z_][\w-]*:\s?", lines[i]):
            fm_lines.append(lines[i])
            i += 1
        if i < len(lines) and lines[i].strip() == "---":
            i += 1  # consume a proper closing fence when one is there
        body_start = i

    fm_text = "\n".join(fm_lines)
    body = "\n".join(lines[body_start:])

    name = None
    desc = None
    nm = re.search(r"^name:\s*(.+)\s*$", fm_text, re.MULTILINE)
    if nm:
        name = nm.group(1).strip().strip("\"'")
    dm = re.search(r"^description:\s*(.+)\s*$", fm_text, re.MULTILINE)
    if dm:
        desc = dm.group(1).strip().strip("\"'")

    if not name:
        name = skill_md.parent.name
    if not desc:
        for line in body.splitlines():
            cleaned = line.strip().lstrip("#").strip()
            if cleaned:
                desc = cleaned
                break
    if not desc:
        desc = "(no description found)"
    return name, desc


def truncate_desc(text: str, limit: int = 110) -> str:
    """Collapse whitespace and clip to ~limit chars for a one-line summary."""
    collapsed = " ".join(text.split())
    if len(collapsed) <= limit:
        return collapsed
    cut = collapsed.rfind(". ", 0, limit)
    if cut > limit // 3:
        return collapsed[: cut + 1]
    return collapsed[: limit - 1].rstrip() + "…"


def render() -> str:
    if not skills_dir.is_dir():
        return ""
    try:
        skill_dirs = sorted(
            (p for p in skills_dir.iterdir() if p.is_dir()),
            key=lambda p: p.name,
        )
    except OSError:
        return ""

    entries: list[tuple[str, str]] = []
    for d in skill_dirs:
        skill_md = d / "SKILL.md"
        if not skill_md.exists():
            continue  # skill dir without SKILL.md — skip silently
        name, desc = parse_skill_md(skill_md)
        entries.append((name, truncate_desc(desc)))

    if not entries:
        return ""

    total = len(entries)
    shown = entries[:SKILLS_LIST_CAP]
    lines = [f"## Installed skills ({total})", ""]
    for name, desc in shown:
        lines.append(f"- **{name}** — {desc}")
    remaining = total - len(shown)
    if remaining > 0:
        lines.append(f"- _(+{remaining} more not shown — see `./skills/`)_")
    lines.append("")
    lines.append(
        "_Read the relevant SKILL.md (via `read_file`) before starting "
        "matching work — Goose has no skill invocation, it's reference "
        "material you read. Pull more with the `find-skills` recipe._"
    )
    return "\n".join(lines)


print(render())
PY
)

if [ -z "$REPORT_TXT" ]; then
  # No ./skills/ dir, or nothing parseable in it — stay silent rather than
  # emit an empty/near-empty section every session.
  exit 0
fi

REPORT_TXT="$REPORT_TXT" python3 <<'PY'
import json, os
ctx = os.environ.get("REPORT_TXT", "")
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}))
PY

exit 0
