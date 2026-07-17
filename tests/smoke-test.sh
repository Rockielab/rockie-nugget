#!/usr/bin/env bash
# rockie-nugget smoke test — dogfoods install.sh in a throwaway HOME.
#
# Asserts that install.sh:
#   • fetches + sha-verifies the goose runtime binary onto PATH,
#   • writes a Goose config that registers the research-env-v1 MCP server,
#   • installs a `nugget` launcher that maps BYOK env → Goose provider,
#   • is idempotent (a second run is a no-op re-verify, no duplicate config),
#   • installs a SessionStart hook that re-surfaces the installed-skills
#     inventory from ./skills/ at session start, falling back cleanly on
#     missing/malformed SKILL.md and capping large counts at 40 (see
#     issue #24 for why this can't yet re-fire after in-session compaction).
#
# Does NOT call a model — that's the live dogfood (see PR body). This proves the
# assembler wrote the right files. Exits 0 on success, 1 on first failure.
#
# Skips the binary fetch unless NUGGET_SMOKE_FETCH=1 (CI without network just
# checks the non-network assertions). On a Linux x86_64 glibc host with network,
# run:  NUGGET_SMOKE_FETCH=1 ./tests/smoke-test.sh
set -u

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; DIM=$'\e[2m'; RESET=$'\e[0m'
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d -t nugget-smoke-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { echo "${GREEN}✓${RESET} $1"; PASS=$((PASS+1)); }
bad()  { echo "${RED}✗ $1${RESET}"; FAIL=$((FAIL+1)); }
have() { [ -e "$1" ] && ok "$2" || bad "$2 (missing: $1)"; }

echo "${YELLOW}▸ rockie-nugget smoke test${RESET}"
echo "${DIM}  scratch HOME: $WORK${RESET}"

# Sandbox every well-known dir into the scratch HOME.
export HOME="$WORK"
export NUGGET_BIN_DIR="$WORK/.local/bin"
export XDG_CONFIG_HOME="$WORK/.config"
export NUGGET_WORKSPACE="$WORK/ws"

BIN="$NUGGET_BIN_DIR"
CONFIG="$XDG_CONFIG_HOME/goose/config.yaml"
HINTS="$XDG_CONFIG_HOME/goose/.goosehints"
RECIPES="$XDG_CONFIG_HOME/goose/recipes"
MEMORY="$XDG_CONFIG_HOME/goose/memory"
PLUGIN="$WORK/.agents/plugins/rockie-nugget"

# ── skill-catalog on-ramp (source-level; runs on every host) ─────────────────
# These assert the *content* of the overlay, so they run before the Linux-only
# platform gate below — otherwise they'd never execute on a contributor's Mac.
echo ""; echo "${YELLOW}── skill catalog on-ramp ──${RESET}"
FS_RECIPE="$REPO/overlay/recipes/find-skills.yaml"
have "$FS_RECIPE" "find-skills recipe present in the overlay"

# Same top-level schema as the recipes that already work. Derived from
# experiment.yaml rather than hardcoded, so this tracks the convention if it
# moves. Deliberately dependency-free (no PyYAML): this file sandboxes $HOME,
# which hides user-site packages, and the rest of the suite imports nothing.
SCHEMA_MISSING=""
for k in $(grep -oE '^[a-z_]+:' "$REPO/overlay/recipes/experiment.yaml" | tr -d ':' | sort -u); do
  grep -qE "^${k}:" "$FS_RECIPE" || SCHEMA_MISSING="$SCHEMA_MISSING $k"
done
[ -z "$SCHEMA_MISSING" ] \
  && ok "find-skills.yaml carries the same top-level recipe schema" \
  || bad "find-skills.yaml missing recipe keys:$SCHEMA_MISSING"
grep -qE '^title: find-skills$' "$FS_RECIPE" \
  && ok "find-skills.yaml declares title: find-skills" \
  || bad "find-skills.yaml title must be find-skills"

# The two runtime-independent CLI facts. Getting either wrong ships guidance
# that 404s (pull by `name`) or that gives up too early (`--search` is a
# substring match, so a name search can miss a skill that exists).
grep -q "catalog_id" "$FS_RECIPE" \
  && ok "find-skills documents pull-by-catalog_id (not the JSON name)" \
  || bad "find-skills must document pull-by-catalog_id"
grep -qi "substring" "$FS_RECIPE" \
  && ok "find-skills documents --search as a substring match" \
  || bad "find-skills must document --search substring semantics"

# Degrade-silently contract: the CLI is never a prerequisite.
grep -q "command -v rockie" "$FS_RECIPE" \
  && ok "find-skills guards on a missing CLI before calling it" \
  || bad "find-skills must guard with command -v rockie"
grep -q "127" "$FS_RECIPE" && grep -q "rockie auth login" "$FS_RECIPE" \
  && ok "find-skills documents not-installed (127) + not-authenticated (2)" \
  || bad "find-skills must document exit 127 and exit 2"

# Nugget-specific correctness: Goose has NO SKILL.md discovery, so a pulled
# skill is reference material you read_file — never an invocable command. This
# is the delta from the Claude/Codex ports and the easiest thing to get wrong.
if grep -qE '(^|[^a-z])[/$](find-skills|grpo-rl-training|serving-llms-vllm)' "$FS_RECIPE"; then
  bad "find-skills implies slash/dollar invocation — Goose has no skill discovery"
else
  ok "find-skills never implies invocable skills (Goose reads markdown)"
fi
grep -q "read_file" "$FS_RECIPE" \
  && ok "find-skills reads the pulled SKILL.md via read_file" \
  || bad "find-skills must read the pulled skill via read_file"

# read_file/write_file are sandboxed to the workspace (_safe_path rejects
# escapes), so a pull must land on a workspace-relative path or be unreadable.
grep -q -- "--out \./skills/" "$FS_RECIPE" \
  && ok "find-skills pulls into the workspace (read_file sandbox)" \
  || bad "find-skills must pull to a workspace-relative path"

grep -q "find-skills" "$REPO/README.md" \
  && ok "README points at the find-skills recipe" \
  || bad "README missing the find-skills recipe"

# On a non-Linux host the platform gate fires by design; assert that and stop.
if [ "$(uname -s)" != "Linux" ]; then
  if bash "$REPO/install.sh" >/dev/null 2>&1; then
    bad "install.sh should refuse to install on non-Linux"
  else
    ok "platform gate refuses non-Linux host (binary is Linux-only)"
  fi
  echo ""; echo "${DIM}  (run the full suite on a Linux x86_64 glibc host)${RESET}"
  echo "${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ── run 1: full install ──────────────────────────────────────────────────────
echo ""; echo "${YELLOW}── install (run 1) ──${RESET}"
INSTALL_LOG="$WORK/install-run1.log"
if [ "${NUGGET_SMOKE_FETCH:-0}" = "1" ]; then
  # The release workflow prepares the raw binary before the Rockie release
  # asset exists. Pre-place that exact executable so install.sh exercises its
  # normal hash-verification/idempotency path without fetching a not-yet-
  # published asset.
  if [ -n "${NUGGET_SMOKE_PREBUILT_GOOSE:-}" ]; then
    if [ ! -f "$NUGGET_SMOKE_PREBUILT_GOOSE" ]; then
      bad "prebuilt Goose binary missing: $NUGGET_SMOKE_PREBUILT_GOOSE"
    else
      mkdir -p "$BIN"
      install -m 0755 "$NUGGET_SMOKE_PREBUILT_GOOSE" "$BIN/goose"
    fi
  fi
  bash "$REPO/install.sh" >"$INSTALL_LOG" 2>&1; INSTALL_EC=$?
  if [ "$INSTALL_EC" -eq 0 ]; then
    ok "install.sh exits 0 on a clean run"
  else
    bad "install.sh exited non-zero ($INSTALL_EC)"
    sed 's/^/  | /' "$INSTALL_LOG"
  fi
  have "$BIN/goose"  "goose runtime binary installed"
  [ -x "$BIN/goose" ] && ok "goose binary is executable" || bad "goose binary not executable"
else
  # No-fetch mode: pre-place a fake binary so config/launcher assertions still run.
  echo "${DIM}  NUGGET_SMOKE_FETCH unset — skipping binary fetch${RESET}"
  mkdir -p "$BIN"; printf '#!/bin/sh\necho fake-goose "$@"\n' > "$BIN/goose"; chmod +x "$BIN/goose"
  # Point the pin at the fake so verify_sha passes on re-run path is not hit;
  # we instead invoke only the config/launcher writers via a guarded run.
  # Capture the exit code explicitly — a swallowed non-zero here is exactly how
  # the launcher-heredoc `MCP_DIR: unbound variable` regression hid from CI.
  NUGGET_SKIP_BINARY=1 bash "$REPO/install.sh" >"$INSTALL_LOG" 2>&1; INSTALL_EC=$?
  if [ "$INSTALL_EC" -eq 0 ]; then
    ok "install.sh exits 0 on a clean run"
  else
    bad "install.sh exited non-zero ($INSTALL_EC)"
    sed 's/^/  | /' "$INSTALL_LOG"
  fi
fi
have "$CONFIG"        "Goose config written"
have "$BIN/nugget"    "nugget launcher installed"
[ -x "$BIN/nugget" ] && ok "nugget launcher is executable" || bad "nugget launcher not executable"
# The launcher heredoc is unquoted, so any var meant for runtime must be escaped.
# `bash -n` parses the generated launcher without running it — catches a syntax
# break and (paired with the run-2 exit-0 assertion) the install-time-unbound
# regression that wrote a broken launcher.
[ -e "$BIN/nugget" ] && bash -n "$BIN/nugget" 2>/dev/null && ok "generated nugget launcher parses (bash -n)" || bad "generated nugget launcher fails bash -n"
grep -Fq '# `goose session export` the turn to persist [LEARN]/[DEAD-END] memory.' "$BIN/nugget" \
  && ok "launcher heredoc preserves literal command text" \
  || bad "launcher heredoc expanded command text while installing"

grep -q "research-env-v1:" "$CONFIG"            && ok "config registers research-env-v1 extension"    || bad "extension not in config"
grep -q "enabled: true"    "$CONFIG"            && ok "extension has enabled: true (required by Goose)" || bad "missing enabled: true"
grep -q "$REPO/mcp/research-env-mcp/server.py" "$CONFIG" && ok "config points at this checkout's MCP server" || bad "MCP server path wrong"
grep -q "memory:" "$CONFIG"                     && ok "config enables the builtin memory extension"   || bad "memory extension not in config"

# ── Rockie overlay (Slices A/D/E) ────────────────────────────────────────────
echo "${DIM}  — Rockie overlay —${RESET}"
have "$HINTS"            ".goosehints written (ethos overlay)"
grep -q "Plan → Research → Build → Audit → Run → Assess → Codify" "$HINTS" && ok ".goosehints carries the Rockie research loop" || bad ".goosehints missing the research loop"
grep -q "rockie-nugget overlay (managed" "$HINTS" && ok ".goosehints uses a managed sentinel block (merge-safe)" || bad ".goosehints missing managed sentinel"
have "$RECIPES/autoresearch.yaml"  "recipe: autoresearch.yaml installed"
have "$RECIPES/experiment.yaml"    "recipe: experiment.yaml installed"
have "$RECIPES/clean.yaml"         "recipe: clean.yaml installed"
have "$RECIPES/find-skills.yaml"   "recipe: find-skills.yaml installed"
grep -q "find-skills.yaml" "$HINTS" && ok ".goosehints advertises the find-skills recipe" || bad ".goosehints missing the find-skills recipe"
have "$PLUGIN/hooks/hooks.json"    "capture hook plugin registered (Open-Plugins manifest at hooks/hooks.json)"
have "$PLUGIN/hooks/capture.sh"    "capture hook script installed"
[ -x "$PLUGIN/hooks/capture.sh" ] && ok "capture hook is executable" || bad "capture hook not executable"
have "$MEMORY/learning.txt"        "memory scaffold: learning.txt seeded"
have "$MEMORY/dead-end.txt"        "memory scaffold: dead-end.txt seeded"
have "$PLUGIN/hooks/session-start.sh" "SessionStart hook script installed"
[ -x "$PLUGIN/hooks/session-start.sh" ] && ok "SessionStart hook is executable" || bad "SessionStart hook not executable"
grep -q '"SessionStart"' "$PLUGIN/hooks/hooks.json" && ok "hooks.json registers SessionStart (not just Stop)" || bad "hooks.json missing SessionStart registration"

# ── Installed skills inventory (SessionStart hook) ───────────────────────────
# find-skills.yaml pulls skills into a workspace-relative ./skills/ (read_file's
# sandbox rejects anything outside the workspace — see that recipe). This hook
# re-surfaces what's there at session start so a pulled skill doesn't silently
# stop getting read once the turn that pulled it ages out of context. Unlike
# rockie-claude/rockie-codex, this canNOT be proven to re-fire after an
# in-session compaction — Goose documents no PreCompact/PostCompact event or
# `compact` SessionStart matcher as of this writing — so these assertions only
# cover the session-start path, which is the part that's actually implemented.
echo ""; echo "${YELLOW}── installed skills inventory (SessionStart hook) ──${RESET}"

SKILLS_WS="$WORK/skills-ws"
mkdir -p "$SKILLS_WS/skills/well-formed"
cat > "$SKILLS_WS/skills/well-formed/SKILL.md" <<'EOF'
---
name: well-formed
description: A normal skill with a clean frontmatter description line.
---

# well-formed
Body text.
EOF

# Malformed frontmatter: opens but never closes, and has no description key —
# only prose follows. Must fall back to the first prose line rather than
# crash the hook or leak a raw YAML/fence line as the "description".
mkdir -p "$SKILLS_WS/skills/malformed-frontmatter"
cat > "$SKILLS_WS/skills/malformed-frontmatter/SKILL.md" <<'EOF'
---
name: malformed-frontmatter

Some prose line that should be picked up as the fallback description.
EOF

# No frontmatter at all — just prose. name falls back to the dir name,
# description falls back to the first non-empty line in the file.
mkdir -p "$SKILLS_WS/skills/no-frontmatter"
cat > "$SKILLS_WS/skills/no-frontmatter/SKILL.md" <<'EOF'
# no-frontmatter

This skill ships with no YAML frontmatter block whatsoever.
EOF

# Skill dir with no SKILL.md at all — must be skipped silently, not fail.
mkdir -p "$SKILLS_WS/skills/no-skill-md/scripts"
echo "print('hi')" > "$SKILLS_WS/skills/no-skill-md/scripts/helper.py"

SKILLS_JSON=$(printf '{"working_dir": "%s"}' "$SKILLS_WS" | bash "$PLUGIN/hooks/session-start.sh" 2>/dev/null)
SKILLS_RC=$?
[ "$SKILLS_RC" = "0" ] && ok "SessionStart hook exits 0 with a populated ./skills/" || bad "SessionStart hook exited $SKILLS_RC"
SKILLS_CTX=$(printf '%s' "$SKILLS_JSON" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: print("")' 2>/dev/null)

[ "$(printf '%s' "$SKILLS_CTX" | grep -c '## Installed skills')" = "1" ] \
  && ok "installed skills section renders" || bad "installed skills section did not render"
printf '%s' "$SKILLS_CTX" | grep -q 'well-formed\*\* — A normal skill with a clean frontmatter' \
  && ok "well-formed skill shows its frontmatter description" || bad "well-formed skill description wrong/missing"
printf '%s' "$SKILLS_CTX" | grep -q 'malformed-frontmatter\*\* — Some prose line that should be picked up' \
  && ok "malformed-frontmatter skill falls back to first prose line, no raw fence/YAML leaked" \
  || bad "malformed-frontmatter fallback wrong/missing"
printf '%s' "$SKILLS_CTX" | grep -q 'no-frontmatter\*\* — no-frontmatter' \
  && ok "no-frontmatter skill falls back to dir name + first line" || bad "no-frontmatter fallback wrong/missing"
[ "$(printf '%s' "$SKILLS_CTX" | grep -c 'no-skill-md')" = "0" ] \
  && ok "no-skill-md dir is skipped, not listed" || bad "no-skill-md dir leaked into the inventory"
printf '%s' "$SKILLS_CTX" | grep -q 'read_file' \
  && ok "nudge tells the agent to read_file the SKILL.md (Goose has no skill invocation)" \
  || bad "nudge missing the read_file guidance"

# Missing ./skills/ dir entirely — silent skip, no crash, no JSON emitted at all.
EMPTY_WS="$WORK/empty-ws"
mkdir -p "$EMPTY_WS"
EMPTY_OUT=$(printf '{"working_dir": "%s"}' "$EMPTY_WS" | bash "$PLUGIN/hooks/session-start.sh" 2>/dev/null)
EMPTY_RC=$?
[ "$EMPTY_RC" = "0" ] && ok "missing ./skills/ dir: hook still exits 0" || bad "missing ./skills/ dir: exit $EMPTY_RC"
[ -z "$EMPTY_OUT" ] && ok "missing ./skills/ dir: no output emitted (stays silent)" || bad "missing ./skills/ dir: unexpected output: $EMPTY_OUT"

# Garbage/empty stdin must never crash the hook (fail-open contract).
printf 'not json {{{' | bash "$PLUGIN/hooks/session-start.sh" >/dev/null 2>&1
[ "$?" = "0" ] && ok "garbage stdin: hook still exits 0" || bad "garbage stdin crashed the hook"

# Large count: cap at 40 with a "+N more" line rather than growing unbounded.
CAP_WS="$WORK/cap-ws"
for i in $(seq -w 1 45); do
  d="$CAP_WS/skills/fixture-skill-$i"
  mkdir -p "$d"
  cat > "$d/SKILL.md" <<EOF
---
name: fixture-skill-$i
description: Fixture skill number $i for the cap test.
---
Body.
EOF
done
CAP_JSON=$(printf '{"working_dir": "%s"}' "$CAP_WS" | bash "$PLUGIN/hooks/session-start.sh" 2>/dev/null)
CAP_CTX=$(printf '%s' "$CAP_JSON" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: print("")' 2>/dev/null)
[ "$(printf '%s' "$CAP_CTX" | grep -c '## Installed skills (45)')" = "1" ] \
  && ok "45 skills: header reports the true total of 45" || bad "45-skill total wrong"
[ "$(printf '%s' "$CAP_CTX" | grep -c '+5 more')" = "1" ] \
  && ok "45 skills: '+5 more' overflow line present" || bad "45-skill overflow line missing"
LISTED_COUNT=$(printf '%s' "$CAP_CTX" | grep -c '^- \*\*fixture-skill-')
[ "$LISTED_COUNT" = "40" ] && ok "45 skills: list itself capped at 40 lines" || bad "45-skill cap not enforced (got $LISTED_COUNT)"

# Masking boundary: the overlay must name no model identity / provider SKU.
if grep -rilE 'deepseek|stone-1|stone1\.0|stone 1\.0' "$HINTS" "$RECIPES" "$PLUGIN" "$MEMORY" 2>/dev/null | grep -q .; then
  bad "overlay leaks a model identity / provider value (masking violation)"
else
  ok "overlay names no model identity (masking boundary holds)"
fi

grep -q "XDG_CONFIG_HOME" "$BIN/nugget"         && ok "launcher pins XDG_CONFIG_HOME (Goose's config var)" || bad "launcher missing XDG_CONFIG_HOME"
grep -q "GOOSE_PROVIDER" "$BIN/nugget"          && ok "launcher maps BYOK → GOOSE_PROVIDER"          || bad "launcher missing provider map"
grep -q "OPENAI_API_KEY" "$BIN/nugget"          && ok "launcher reads OPENAI_API_KEY (BYOK)"         || bad "launcher missing OPENAI_API_KEY"
grep -q "ANTHROPIC_API_KEY" "$BIN/nugget"       && ok "launcher reads ANTHROPIC_API_KEY (BYOK)"      || bad "launcher missing ANTHROPIC_API_KEY"

# `nugget login` wires the device flow (shells rockie_auth.py). Assert the wiring
# statically — do NOT exec it: the device-flow poll loop blocks indefinitely
# waiting on the backend, which would hang the suite.
grep -q "rockie_auth.py" "$BIN/nugget" && ok "nugget login wires the device-flow client" || bad "login branch not wired to rockie_auth.py"
# Masking boundary: the login wiring must name no served-model identity / SKU /
# endpoint. The generic BYOK placeholder (api.your-provider.com) is fine; a real
# served-model endpoint/identity must NEVER appear in the launcher.
if grep -qiE 'stone|rockielab\.com/v1|served-model-key|GOOSE_PROVIDER=[a-z]' "$BIN/nugget"; then
  bad "launcher leaks served-model values (masking violation)"
else
  ok "launcher leaks no served-model values"
fi

# launcher refuses with no key.
if HOME="$WORK" "$BIN/nugget" run "hi" >/dev/null 2>&1; then
  bad "launcher should refuse to run with no model key"
else
  ok "launcher refuses to run with no model key set"
fi

# ── run 2: idempotency ───────────────────────────────────────────────────────
echo ""; echo "${YELLOW}── idempotency (run 2) ──${RESET}"
CFG_BEFORE="$(cat "$CONFIG")"
INSTALL_LOG_RUN2="$WORK/install-run2.log"
if [ "${NUGGET_SMOKE_FETCH:-0}" = "1" ]; then
  bash "$REPO/install.sh" >"$INSTALL_LOG_RUN2" 2>&1; INSTALL_EC=$?
else
  NUGGET_SKIP_BINARY=1 bash "$REPO/install.sh" >"$INSTALL_LOG_RUN2" 2>&1; INSTALL_EC=$?
fi
if [ "$INSTALL_EC" -eq 0 ]; then
  ok "second install.sh run exits 0"
else
  bad "second install.sh run exited non-zero ($INSTALL_EC)"
  sed 's/^/  | /' "$INSTALL_LOG_RUN2"
fi
[ "$(cat "$CONFIG")" = "$CFG_BEFORE" ] && ok "config unchanged on re-run (idempotent)" || bad "config drifted on re-run"
[ "$(grep -c 'research-env-v1:' "$CONFIG")" = "1" ] && ok "no duplicate extension block on re-run" || bad "duplicate extension block"
[ "$(grep -c 'rockie-nugget overlay (managed' "$HINTS")" = "1" ] && ok "no duplicate .goosehints managed block on re-run (merge idempotent)" || bad ".goosehints managed block duplicated on re-run"

echo ""
echo "${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
