#!/usr/bin/env bash
# rockie-nugget smoke test — dogfoods install.sh in a throwaway HOME.
#
# Asserts that install.sh:
#   • fetches + sha-verifies the goose runtime binary onto PATH,
#   • writes a Goose config that registers the research-env-v1 MCP server,
#   • installs a `nugget` launcher that maps BYOK env → Goose provider,
#   • is idempotent (a second run is a no-op re-verify, no duplicate config).
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
if [ "${NUGGET_SMOKE_FETCH:-0}" = "1" ]; then
  bash "$REPO/install.sh" >/dev/null 2>&1; INSTALL_EC=$?
  [ "$INSTALL_EC" -eq 0 ] && ok "install.sh exits 0 on a clean run" || bad "install.sh exited non-zero ($INSTALL_EC)"
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
  NUGGET_SKIP_BINARY=1 bash "$REPO/install.sh" >/dev/null 2>&1; INSTALL_EC=$?
  [ "$INSTALL_EC" -eq 0 ] && ok "install.sh exits 0 on a clean run" || bad "install.sh exited non-zero ($INSTALL_EC)"
fi

have "$CONFIG"        "Goose config written"
have "$BIN/nugget"    "nugget launcher installed"
[ -x "$BIN/nugget" ] && ok "nugget launcher is executable" || bad "nugget launcher not executable"
# The launcher heredoc is unquoted, so any var meant for runtime must be escaped.
# `bash -n` parses the generated launcher without running it — catches a syntax
# break and (paired with the run-2 exit-0 assertion) the install-time-unbound
# regression that wrote a broken launcher.
[ -e "$BIN/nugget" ] && bash -n "$BIN/nugget" 2>/dev/null && ok "generated nugget launcher parses (bash -n)" || bad "generated nugget launcher fails bash -n"

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
have "$PLUGIN/hooks/hooks.json"    "capture hook plugin registered (Open-Plugins manifest at hooks/hooks.json)"
have "$PLUGIN/hooks/capture.sh"    "capture hook script installed"
[ -x "$PLUGIN/hooks/capture.sh" ] && ok "capture hook is executable" || bad "capture hook not executable"
have "$MEMORY/learning.txt"        "memory scaffold: learning.txt seeded"
have "$MEMORY/dead-end.txt"        "memory scaffold: dead-end.txt seeded"

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
if [ "${NUGGET_SMOKE_FETCH:-0}" = "1" ]; then
  bash "$REPO/install.sh" >/dev/null 2>&1 || bad "second install.sh run exited non-zero"
else
  NUGGET_SKIP_BINARY=1 bash "$REPO/install.sh" >/dev/null 2>&1 || bad "second install.sh run exited non-zero"
fi
[ "$(cat "$CONFIG")" = "$CFG_BEFORE" ] && ok "config unchanged on re-run (idempotent)" || bad "config drifted on re-run"
[ "$(grep -c 'research-env-v1:' "$CONFIG")" = "1" ] && ok "no duplicate extension block on re-run" || bad "duplicate extension block"
[ "$(grep -c 'rockie-nugget overlay (managed' "$HINTS")" = "1" ] && ok "no duplicate .goosehints managed block on re-run (merge idempotent)" || bad ".goosehints managed block duplicated on re-run"

echo ""
echo "${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
