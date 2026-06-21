#!/usr/bin/env bash
# arena-lib.sh — shared fixtures for the multi-task nugget Model Arena.
#
# Design (scaffold-confound discipline): the HARNESS is fixed (nugget = goose +
# research-env-v1 MCP). Only the MODEL varies, supplied via generic env:
#   OPENAI_BASE_URL / OPENAI_API_KEY / GOOSE_MODEL  (+ optional GOOSE_PROVIDER).
# Every model sees the SAME staged workspace per task (re-staged fresh per run),
# the SAME task prompt, and is graded by the SAME deterministic grader.
#
# This library is GENERIC: it names no model and no provider. Model identity comes
# from env at call time and is never written into a committed artifact.
set -uo pipefail

# --- locations (override via env) ---------------------------------------------
ARENA_DIR="${ARENA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$ARENA_DIR/../.." && pwd)}"
TASKS_DIR="${TASKS_DIR:-$ARENA_DIR/tasks}"
MCP_SERVER="${MCP_SERVER:-$REPO_ROOT/mcp/research-env-mcp/server.py}"
CONTRACT_DIR="${CONTRACT_DIR:-$REPO_ROOT/contract/research-env-v1}"

# nugget (goose) binary + an isolated XDG config home so we don't clobber a user's.
GOOSE="${GOOSE:-goose}"
ARENA_XDG="${ARENA_XDG:-/tmp/nugget-arena-xdg}"
GOOSE_CONFIG="$ARENA_XDG/.config/goose/config.yaml"

PER_RUN_TIMEOUT="${PER_RUN_TIMEOUT:-900}"
ARENA_WORK="${ARENA_WORK:-/tmp/nugget-arena-work}"   # staged workspaces + outputs

# timeout wrapper — `timeout` (coreutils) on Linux/Hetzner, `gtimeout` if present,
# else run unwrapped (e.g. stock macOS without coreutils). Keeps the runner portable.
_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@";
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@";
  else shift; "$@"; fi
}

# Which tasks make up the suite. Override ARENA_TASKS to subset.
# super-pie-perf is OPTIONAL (needs gdrive staging); include it only if its
# workspace snapshot is provided via PIE_PERF_SNAPSHOT.
ARENA_TASKS="${ARENA_TASKS:-algo-twosum algo-anagram-groups data-extract-csv fix-failing-test}"

# --- goose config: mount research-env-v1, pointed at a given workspace ---------
write_goose_config() {
  local ws="$1"
  mkdir -p "$(dirname "$GOOSE_CONFIG")"
  cat > "$GOOSE_CONFIG" <<EOF
extensions:
  research-env-v1:
    enabled: true
    type: stdio
    name: research-env-v1
    description: Rockie research action space (research-env-v1) over MCP stdio
    cmd: python3
    args:
      - $MCP_SERVER
    envs:
      RESEARCH_ENV_CONTRACT_DIR: $CONTRACT_DIR
      RESEARCH_ENV_WORKSPACE: $ws
    timeout: 300
EOF
}

# --- per-task workspace staging -----------------------------------------------
# Echoes the staged workspace path. Re-stages fresh every call (fairness).
stage_task() {
  local task="$1" model_label="$2"
  local ws="$ARENA_WORK/$model_label/$task/ws"
  if [ "$task" = "super-pie-perf" ]; then
    # snapshot-based staging: copy a pre-staged pie-perf snapshot (clone + gdrive
    # inputs) supplied out-of-band via PIE_PERF_SNAPSHOT. Keeps gdrive out of CI.
    : "${PIE_PERF_SNAPSHOT:?super-pie-perf requires PIE_PERF_SNAPSHOT=<pre-staged repo dir>}"
    rm -rf "$ws"; mkdir -p "$(dirname "$ws")"
    cp -a "$PIE_PERF_SNAPSHOT" "$ws"
  else
    WORKSPACE="$ws" bash "$TASKS_DIR/$task/prepare.sh" >&2
  fi
  echo "$ws"
}

# --- per-task prompt ----------------------------------------------------------
# Generic header naming nugget's action space, then the task's own prompt.
task_prompt() {
  local task="$1"
  local header="You are an autonomous research/coding agent. Use ONLY the research-env-v1 extension tools (list_files, read_file, write_file, run_command, finish). Do NOT use any built-in shell/developer/editor tools."
  local body
  body="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prompt"])' "$TASKS_DIR/$task/task.json")"
  printf '%s\n\n%s\n' "$header" "$body"
}

# answer artifact path the grader reads, relative to the workspace root.
task_answer_artifact() {
  local task="$1"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["answer_artifact"])' "$TASKS_DIR/$task/task.json"
}

# --- deterministic grading ----------------------------------------------------
# Writes grade.json into $outdir; echoes the output_match float.
grade_task() {
  local task="$1" ws="$2" outdir="$3"
  local artifact; artifact="$(task_answer_artifact "$task")"
  local answer="$ws/$artifact"
  mkdir -p "$outdir"
  local extra=()
  # data-extract-csv's grader recomputes its oracle from the staged workspace.
  if [ "$task" = "data-extract-csv" ]; then extra=(--workspace "$ws"); fi
  if [ -f "$answer" ]; then
    cp "$answer" "$outdir/$(basename "$artifact")" 2>/dev/null || true
    python3 "$TASKS_DIR/$task/grade.py" --task "$TASKS_DIR/$task/task.json" \
      --answer "$answer" "${extra[@]}" > "$outdir/grade.json" 2>"$outdir/grade.err"
  else
    echo "{\"task_id\":\"$task\",\"output_match\":0.0,\"note\":\"no answer artifact ($artifact) written\"}" > "$outdir/grade.json"
  fi
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("output_match",0.0))' "$outdir/grade.json"
}

# --- run one task for one model ----------------------------------------------
# Stages, runs nugget, grades. Echoes "<task> <output_match>".
run_task_for_model() {
  local task="$1" model_label="$2"
  : "${OPENAI_BASE_URL:?set OPENAI_BASE_URL}"
  : "${OPENAI_API_KEY:?set OPENAI_API_KEY inline}"
  : "${GOOSE_MODEL:?set GOOSE_MODEL}"
  local outdir="$ARENA_WORK/$model_label/$task/out"
  mkdir -p "$outdir"
  local ws; ws="$(stage_task "$task" "$model_label")"
  write_goose_config "$ws"
  local prompt; prompt="$(task_prompt "$task")"
  local start end rc
  start=$(date +%s)
  ( cd "$ws" \
      && export XDG_CONFIG_HOME="$ARENA_XDG/.config" \
         OPENAI_API_KEY="$OPENAI_API_KEY" OPENAI_BASE_URL="$OPENAI_BASE_URL" \
         GOOSE_PROVIDER="${GOOSE_PROVIDER:-openai}" GOOSE_MODEL="$GOOSE_MODEL" \
         GOOSE_CONTEXT_LIMIT="${GOOSE_CONTEXT_LIMIT:-120000}" \
      && _timeout "$PER_RUN_TIMEOUT" "$GOOSE" run --no-session -t "$prompt" ) \
      > "$outdir/transcript.txt" 2>&1
  rc=$?; end=$(date +%s)
  echo "$rc" > "$outdir/exit_code"
  echo "$((end-start))" > "$outdir/duration_s"
  sha256sum "$outdir/transcript.txt" 2>/dev/null | cut -d' ' -f1 > "$outdir/transcript.sha256"
  local score; score="$(grade_task "$task" "$ws" "$outdir")"
  echo "$task $score"
}
