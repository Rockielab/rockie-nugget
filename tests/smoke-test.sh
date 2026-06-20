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
  bash "$REPO/install.sh" >/dev/null 2>&1 || { bad "install.sh exited non-zero"; }
  have "$BIN/goose"  "goose runtime binary installed"
  [ -x "$BIN/goose" ] && ok "goose binary is executable" || bad "goose binary not executable"
else
  # No-fetch mode: pre-place a fake binary so config/launcher assertions still run.
  echo "${DIM}  NUGGET_SMOKE_FETCH unset — skipping binary fetch${RESET}"
  mkdir -p "$BIN"; printf '#!/bin/sh\necho fake-goose "$@"\n' > "$BIN/goose"; chmod +x "$BIN/goose"
  # Point the pin at the fake so verify_sha passes on re-run path is not hit;
  # we instead invoke only the config/launcher writers via a guarded run.
  NUGGET_SKIP_BINARY=1 bash "$REPO/install.sh" >/dev/null 2>&1 || true
fi

have "$CONFIG"        "Goose config written"
have "$BIN/nugget"    "nugget launcher installed"
[ -x "$BIN/nugget" ] && ok "nugget launcher is executable" || bad "nugget launcher not executable"

grep -q "research-env-v1:" "$CONFIG"            && ok "config registers research-env-v1 extension"    || bad "extension not in config"
grep -q "enabled: true"    "$CONFIG"            && ok "extension has enabled: true (required by Goose)" || bad "missing enabled: true"
grep -q "$REPO/mcp/research-env-mcp/server.py" "$CONFIG" && ok "config points at this checkout's MCP server" || bad "MCP server path wrong"

grep -q "XDG_CONFIG_HOME" "$BIN/nugget"         && ok "launcher pins XDG_CONFIG_HOME (Goose's config var)" || bad "launcher missing XDG_CONFIG_HOME"
grep -q "GOOSE_PROVIDER" "$BIN/nugget"          && ok "launcher maps BYOK → GOOSE_PROVIDER"          || bad "launcher missing provider map"
grep -q "OPENAI_API_KEY" "$BIN/nugget"          && ok "launcher reads OPENAI_API_KEY (BYOK)"         || bad "launcher missing OPENAI_API_KEY"
grep -q "ANTHROPIC_API_KEY" "$BIN/nugget"       && ok "launcher reads ANTHROPIC_API_KEY (BYOK)"      || bad "launcher missing ANTHROPIC_API_KEY"

# login stub must be present and value-free (masking boundary).
"$BIN/nugget" login 2>&1 | grep -qi "coming soon" && ok "nugget login is a labeled 'coming soon' stub" || bad "login stub missing/mislabeled"
# Masking boundary: the login stub must not name the served model. The generic
# BYOK placeholder (OPENAI_BASE_URL=api.your-provider.com) is fine; what must
# NEVER appear is a real served-model endpoint/identity.
if "$BIN/nugget" login 2>&1 | grep -qiE 'stone|rockielab\.com/v1|served-model-key|GOOSE_PROVIDER=[a-z]'; then
  bad "login stub leaks served-model values (masking violation)"
else
  ok "login stub leaks no served-model values"
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
  NUGGET_SKIP_BINARY=1 bash "$REPO/install.sh" >/dev/null 2>&1 || true
fi
[ "$(cat "$CONFIG")" = "$CFG_BEFORE" ] && ok "config unchanged on re-run (idempotent)" || bad "config drifted on re-run"
[ "$(grep -c 'research-env-v1:' "$CONFIG")" = "1" ] && ok "no duplicate extension block on re-run" || bad "duplicate extension block"

echo ""
echo "${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
