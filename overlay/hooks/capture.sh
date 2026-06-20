#!/usr/bin/env bash
# nugget Stop hook — durable [LEARN]/[DEAD-END] capture (config-only, no SQLite).
#
# Goose hooks are advisory (non-blocking). This one only *captures*, never gates,
# so advisory is exactly right. It scans the last assistant turn for [LEARN] and
# [DEAD-END] blocks and appends them to plain-text files under the Goose memory
# dir — the same dir Goose's builtin memory extension reads with
# `retrieve_memories`, so the next session can recall them.
#
#   [LEARN] <category>: <rule>            -> memory/learning.txt   (Goose category)
#   [DEAD-END] <slug>: <reason>           -> memory/dead-end.txt    (Goose category)
#
# Goose memory category-file format is plain entries separated by a blank line;
# the first line is the entry, a leading `# tag` line attaches retrieval tags.
#
# Fail-open: any error exits 0 so a broken hook never blocks the session.
#
# Goose's Open-Plugins Stop payload (JSON on stdin) carries `session_id`, not a
# transcript path — the session lives in Goose's session store. We recover the
# turn text with `goose session export --format json`. For portability the hook
# also accepts a `transcript_path` (Claude-Code/Codex shape) or a file argument.
set +e

MEM_DIR="${GOOSE_MEMORY_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/goose/memory}"
mkdir -p "$MEM_DIR" 2>/dev/null

INPUT="$(cat 2>/dev/null)"
SESSION_ID="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id","") or "")
except Exception: print("")' 2>/dev/null)"
TRANSCRIPT="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("transcript_path","") or "")
except Exception: print("")' 2>/dev/null)"
[ -z "$TRANSCRIPT" ] && TRANSCRIPT="${GOOSE_TRANSCRIPT_PATH:-${1:-}}"

# Resolve the session text into $SRC (a temp file the python reads).
GOOSE_BIN="${GOOSE_BIN:-$(command -v goose 2>/dev/null)}"
SRC=""
if [ -n "$SESSION_ID" ] && [ -n "$GOOSE_BIN" ]; then
  SRC="$(mktemp 2>/dev/null)"
  if ! "$GOOSE_BIN" session export --session-id "$SESSION_ID" --format json >"$SRC" 2>/dev/null || [ ! -s "$SRC" ]; then
    rm -f "$SRC" 2>/dev/null; SRC=""
  fi
fi
if [ -z "$SRC" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  SRC="$TRANSCRIPT"
fi
[ -z "$SRC" ] && { echo "[capture] no session text available (session_id=$SESSION_ID); nothing to do" >&2; exit 0; }

python3 - "$SRC" "$MEM_DIR" <<'PY'
import sys, re, json, pathlib

transcript_path, mem_dir = sys.argv[1], sys.argv[2]
file_text = pathlib.Path(transcript_path).read_text(errors="ignore")

# Source may be (a) a Goose `session export --format json` document — a dict with
# a `conversation` list of {role, content}; (b) JSONL — one {type, message} per
# line (Claude/Codex shape); or (c) plain text. Prefer structured parsing so
# escaped "\n" become real newlines (the block anchors rely on real blank
# lines); fall back to raw bytes otherwise. We only keep assistant-authored text.
def content_text(content):
    if isinstance(content, str):
        return content
    out = []
    for b in (content or []):
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
    return "\n".join(out)

def assistant_text(file_text):
    # (a) whole-file JSON document with a conversation array.
    try:
        doc = json.loads(file_text)
    except Exception:
        doc = None
    if isinstance(doc, dict):
        msgs = doc.get("conversation") or doc.get("messages") or []
        chunks = [content_text(m.get("content"))
                  for m in msgs
                  if isinstance(m, dict) and m.get("role") == "assistant"]
        return ("\n\n".join(c for c in chunks if c), True)
    # (b) JSONL, one entry per line.
    chunks, any_json = [], False
    for line in file_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        any_json = True
        if not isinstance(entry, dict):
            continue
        if entry.get("type") == "assistant":
            chunks.append(content_text(entry.get("message", {}).get("content")))
        elif entry.get("role") == "assistant":
            chunks.append(content_text(entry.get("content")))
    return ("\n\n".join(c for c in chunks if c), any_json)

text, was_json = assistant_text(file_text)
raw = text if was_json else file_text
learn_re = re.compile(
    r'\[LEARN(?:\s+([\w\-]+))?\]\s*([\w][\w\s\-/]*?)\s*:\s*(.+?)'
    r'(?:\n\s*Mistake:\s*(.+?))?'
    r'(?:\n\s*Correction:\s*(.+?))?'
    r'(?=\n\s*\[LEARN|\n\s*\[DEAD-END|\n\s*\n|\Z)',
    re.DOTALL | re.IGNORECASE,
)
dead_re = re.compile(
    r'\[DEAD-END\]\s*([\w][\w\s\-/]*?)\s*:\s*(.+?)'
    r'(?:\n\s*Evidence:\s*(.+?))?'
    r'(?=\n\s*\[LEARN|\n\s*\[DEAD-END|\n\s*\n|\Z)',
    re.DOTALL | re.IGNORECASE,
)

def first_line(s):
    return (s or "").strip().split("\n")[0].strip()

def append_entry(path, tag, body):
    path = pathlib.Path(path)
    existing = path.read_text(errors="ignore") if path.exists() else ""
    if body.strip() in existing:          # idempotent: dedupe on entry text
        return False
    block = f"# {tag}\n{body.strip()}\n\n"
    with path.open("a") as f:
        f.write(block)
    return True

n = 0
for tag, category, rule, mistake, correction in learn_re.findall(raw):
    rule = first_line(rule)
    if not rule:
        continue
    parts = [f"[{category.strip()}] {rule}"]
    if mistake and mistake.strip():
        parts.append(f"Mistake: {first_line(mistake)}")
    if correction and correction.strip():
        parts.append(f"Correction: {first_line(correction)}")
    rt = "learning harness-upstream" if (tag or "").lower() == "harness-upstream" else "learning"
    if append_entry(pathlib.Path(mem_dir) / "learning.txt", rt, "\n".join(parts)):
        n += 1

for slug, reason, evidence in dead_re.findall(raw):
    reason = first_line(reason)
    if not reason:
        continue
    parts = [f"[{slug.strip()}] {reason}"]
    if evidence and evidence.strip():
        parts.append(f"Evidence: {first_line(evidence)}")
    if append_entry(pathlib.Path(mem_dir) / "dead-end.txt", "dead-end", "\n".join(parts)):
        n += 1

if n:
    print(f"[capture] persisted {n} memory entr{'y' if n == 1 else 'ies'} -> {mem_dir}",
          file=sys.stderr)
PY
exit 0
