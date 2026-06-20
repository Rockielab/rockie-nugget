#!/usr/bin/env bash
# rockie-nugget — local installer (BYOK).
#
# Assembles a working `nugget` from config only — local install ≡ platform runtime:
#   1. fetches the released Goose runtime binary (sha-verified) onto PATH,
#   2. registers this repo's research-env-v1 MCP server as the tool surface,
#   3. writes a Goose config + a `nugget` launcher that wraps `goose run`.
#
# Bring your own model key (BYOK) — any OpenAI- or Anthropic-compatible endpoint:
#   export OPENAI_BASE_URL=https://api.your-provider.com OPENAI_API_KEY=sk-...
#   nugget run "your research task"
#
# Usage:
#   ./install.sh            # install / update (idempotent)
#   ./install.sh --help
#
# Idempotent: re-running re-verifies the binary, refreshes config + launcher,
# and never clobbers unrelated Goose extensions you've added yourself.
set -euo pipefail

# ── release pin (the only thing that changes when Goose is rebuilt) ──────────
GOOSE_TAG="nugget-goose-v1.38.0-glibc236"
GOOSE_ASSET="goose"
GOOSE_SHA256="489391da775fcdafbda8bf2322b15580938f3fdad243cc8e7d03bc1e0530be98"
GOOSE_REPO="Rockielab/rockie-nugget"

# ── install locations (well-known dirs only) ────────────────────────────────
BIN_DIR="${NUGGET_BIN_DIR:-$HOME/.local/bin}"
# Goose reads its config from $XDG_CONFIG_HOME/goose (default ~/.config/goose).
# We derive from XDG_CONFIG_HOME so the launcher and Goose always agree, and so
# `XDG_CONFIG_HOME=/some/dir ./install.sh` actually redirects Goose.
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
GOOSE_CONFIG_DIR="$XDG_CONFIG_HOME/goose"
WORKSPACE_DIR="${NUGGET_WORKSPACE:-$HOME/.local/share/nugget/workspace}"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
MCP_SERVER="$REPO_ROOT/mcp/research-env-mcp/server.py"
CONTRACT_DIR="$REPO_ROOT/contract/research-env-v1"
SKILLS_SRC="$REPO_ROOT/skills"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

say "┌── rockie-nugget installer (BYOK) ────────────────────────"
say "│  goose binary  →  $BIN_DIR/goose"
say "│  nugget cmd    →  $BIN_DIR/nugget"
say "│  goose config  →  $GOOSE_CONFIG_DIR/config.yaml"
say "│  workspace     →  $WORKSPACE_DIR"
say "└──────────────────────────────────────────────────────────"

# ── platform gate ───────────────────────────────────────────────────────────
# The hosted Goose binary is a glibc-2.36 Linux x86_64 build. Fail loudly on
# anything else rather than installing something that won't run.
OS="$(uname -s)"
ARCH="$(uname -m)"
if [ "$OS" != "Linux" ]; then
  die "the prebuilt Goose runtime is Linux-only (got $OS).
       Run rockie-nugget on a Linux x86_64 host (a server or container).
       Native macOS support is planned — see issue #1953."
fi
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
  die "the prebuilt Goose runtime is x86_64-only (got $ARCH). See issue #1953."
fi
# glibc check — the binary needs glibc >= 2.36; musl (Alpine) won't work.
if ! ldd --version 2>&1 | grep -qiE 'glibc|gnu libc'; then
  die "could not confirm a glibc C library (musl/Alpine is unsupported).
       Use a glibc-2.36+ Linux host (Debian bookworm, Ubuntu 22.04+)."
fi

# ── preflight ───────────────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || die "python3 is required (the MCP tool server is Python). Install python3 and retry."
command -v curl    >/dev/null 2>&1 || die "curl is required to fetch the runtime binary."
[ -f "$MCP_SERVER" ] || die "MCP server not found at $MCP_SERVER — run this from a rockie-nugget checkout."
[ -d "$CONTRACT_DIR" ] || die "tool contract not found at $CONTRACT_DIR — run this from a rockie-nugget checkout."

SHACMD=""
if command -v sha256sum >/dev/null 2>&1; then SHACMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHACMD="shasum -a 256"
else die "need sha256sum or shasum to verify the binary download."; fi

verify_sha() {
  local file="$1" want="$2" got
  got="$($SHACMD "$file" | awk '{print $1}')"
  [ "$got" = "$want" ]
}

mkdir -p "$BIN_DIR" "$GOOSE_CONFIG_DIR" "$WORKSPACE_DIR"

# ── 1. fetch + verify the Goose runtime binary ──────────────────────────────
GOOSE_BIN="$BIN_DIR/goose"
if [ "${NUGGET_SKIP_BINARY:-0}" = "1" ]; then
  say "[.] NUGGET_SKIP_BINARY=1 — skipping runtime fetch (test mode)"
elif [ -f "$GOOSE_BIN" ] && verify_sha "$GOOSE_BIN" "$GOOSE_SHA256"; then
  say "[.] goose runtime already present and verified ($GOOSE_TAG)"
else
  URL="https://github.com/$GOOSE_REPO/releases/download/$GOOSE_TAG/$GOOSE_ASSET"
  say "[+] fetching goose runtime ($GOOSE_TAG) …"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download "$GOOSE_TAG" -R "$GOOSE_REPO" -p "$GOOSE_ASSET" -O "$tmp" --clobber
  else
    curl -fSL --retry 3 -o "$tmp" "$URL" || die "download failed: $URL"
  fi
  verify_sha "$tmp" "$GOOSE_SHA256" || die "sha256 mismatch on downloaded goose binary — refusing to install.
       expected $GOOSE_SHA256
       got      $($SHACMD "$tmp" | awk '{print $1}')"
  install -m 0755 "$tmp" "$GOOSE_BIN"
  rm -f "$tmp"; trap - EXIT
  say "[+] installed goose runtime → $GOOSE_BIN"
fi

# ── 2. install the Rockie skills overlay, if this checkout ships one ─────────
SKILLS_DST="$GOOSE_CONFIG_DIR/skills"
if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$SKILLS_DST"
  cp -a "$SKILLS_SRC/." "$SKILLS_DST/"
  say "[+] installed Rockie skills overlay → $SKILLS_DST"
fi

# ── 3. write the Goose config (registers the MCP server as the tool surface) ─
# enabled:true is REQUIRED — Goose silently drops an extension entry without it.
CONFIG="$GOOSE_CONFIG_DIR/config.yaml"
python3 - "$CONFIG" "$MCP_SERVER" "$CONTRACT_DIR" "$WORKSPACE_DIR" <<'PY'
import sys
config, server, contract, workspace = sys.argv[1:5]
block = f"""extensions:
  research-env-v1:
    enabled: true            # REQUIRED — Goose silently drops the extension without it
    type: stdio
    name: research-env-v1
    description: Rockie research action space (research-env-v1) — 9 tools over MCP stdio
    cmd: python3
    args:
      - {server}
    envs:
      RESEARCH_ENV_CONTRACT_DIR: {contract}
      RESEARCH_ENV_WORKSPACE: {workspace}
    timeout: 300
"""
open(config, "w").write(block)
print(f"[+] wrote Goose config → {config}")
PY

# ── 4. create the `nugget` launcher (wraps `goose run` with BYOK → provider) ─
# BYOK env mapping happens here so users never hand-edit Goose provider config:
#   OPENAI_BASE_URL + OPENAI_API_KEY  → GOOSE_PROVIDER=openai
#   ANTHROPIC_API_KEY                 → GOOSE_PROVIDER=anthropic
NUGGET="$BIN_DIR/nugget"
cat > "$NUGGET" <<NUGGET_EOF
#!/usr/bin/env bash
# nugget — thin launcher for the rockie-nugget research harness (BYOK).
# Wraps the Goose runtime with the research-env-v1 tool surface.
#
#   export OPENAI_BASE_URL=https://api.your-provider.com OPENAI_API_KEY=sk-...
#   nugget run "your research task"
set -euo pipefail

GOOSE="$GOOSE_BIN"
# Pin Goose at the config this install wrote (Goose reads \$XDG_CONFIG_HOME/goose).
export XDG_CONFIG_HOME="\${XDG_CONFIG_HOME:-$XDG_CONFIG_HOME}"

case "\${1:-}" in
  run)
    shift
    ;;
  login)
    cat >&2 <<'MSG'
nugget login: the Rockie served model is coming soon.
For now, bring your own key (BYOK) against any compatible endpoint:
  export OPENAI_BASE_URL=https://api.your-provider.com OPENAI_API_KEY=sk-...
  nugget run "your task"
MSG
    exit 0
    ;;
  ""|-h|--help)
    cat >&2 <<'MSG'
nugget — open research harness (BYOK)

Usage:
  nugget run "<task>"     run a research task to completion (headless)
  nugget login           (served model — coming soon)

Model (bring your own key):
  OpenAI-compatible:   export OPENAI_BASE_URL=... OPENAI_API_KEY=sk-...
  Anthropic:           export ANTHROPIC_API_KEY=sk-ant-...
  GOOSE_MODEL          pick the model name (default: deepseek-chat for openai-compatible)
MSG
    exit 0
    ;;
  *)
    exec "\$GOOSE" "\$@"
    ;;
esac

# ── BYOK → Goose provider mapping ───────────────────────────────────────────
if [ -n "\${OPENAI_API_KEY:-}" ]; then
  export GOOSE_PROVIDER="\${GOOSE_PROVIDER:-openai}"
  export GOOSE_MODEL="\${GOOSE_MODEL:-deepseek-chat}"
elif [ -n "\${ANTHROPIC_API_KEY:-}" ]; then
  export GOOSE_PROVIDER="\${GOOSE_PROVIDER:-anthropic}"
  export GOOSE_MODEL="\${GOOSE_MODEL:-claude-sonnet-4-20250514}"
else
  echo "nugget: no model key set. Export OPENAI_API_KEY (+OPENAI_BASE_URL) or ANTHROPIC_API_KEY." >&2
  exit 2
fi

exec "\$GOOSE" run --no-session -t "\$*"
NUGGET_EOF
chmod +x "$NUGGET"
say "[+] installed nugget launcher → $NUGGET"

# ── PATH nudge ──────────────────────────────────────────────────────────────
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say ""
     say "note: $BIN_DIR is not on your PATH. Add it:"
     say "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
esac

say ""
say "✓ rockie-nugget install complete."
say ""
say "  next:"
say "    export OPENAI_BASE_URL=https://api.your-provider.com OPENAI_API_KEY=sk-..."
say "    nugget run \"what is 17 times 23\""
