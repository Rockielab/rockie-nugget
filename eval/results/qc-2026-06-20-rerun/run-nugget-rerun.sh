#!/usr/bin/env bash
# run-nugget-rerun.sh <trial> <base_url> <model> <api_key>
# Re-run of the nugget QC leg AFTER the run_command faithful-output fix (PR #7).
# Uses the FRESHLY INSTALLED nugget from main (binary + fixed research-env MCP).
set -uo pipefail
source /root/nugget-qc-rerun-2026-06-20/qc-lib.sh
TRIAL="$1"; BASE_URL="$2"; MODEL="$3"; API_KEY="$4"

# Freshly-installed nugget (./install.sh from main) — isolated XDG home.
NUGGET_HOME=/root/nugget-rerun-install
GOOSE="$NUGGET_HOME/bin/goose"
export XDG_CONFIG_HOME="$NUGGET_HOME/.config"
CONFIG="$XDG_CONFIG_HOME/goose/config.yaml"

LABEL="nugget-t$TRIAL"
OUTDIR="$RES/$LABEL"; mkdir -p "$OUTDIR"

REPO=$(stage_ws "$LABEL")
# point research-env-v1 MCP workspace at this fresh repo (same mechanism as orig)
python3 - "$CONFIG" "$REPO" <<PY
import sys,re
cfg,ws=sys.argv[1],sys.argv[2]
t=open(cfg).read()
t=re.sub(r"RESEARCH_ENV_WORKSPACE:.*", f"RESEARCH_ENV_WORKSPACE: {ws}", t)
open(cfg,"w").write(t)
PY

TASK="You are evaluating a code-improvement model on the pie-perf benchmark. Use ONLY the research-env-v1 extension tools (list_files, read_file, write_file, run_command, finish). Do NOT use built-in shell/developer tools.

$(core_task)

Write your final json-list report to answer.json using write_file, then call finish."

cd "$REPO"
START=$(date +%s)
env OPENAI_API_KEY="$API_KEY" OPENAI_BASE_URL="$BASE_URL" \
    GOOSE_PROVIDER=openai GOOSE_MODEL="$MODEL" GOOSE_CONTEXT_LIMIT=120000 \
  timeout "$PER_RUN_TIMEOUT" "$GOOSE" run --no-session -t "$TASK" > "$OUTDIR/transcript.txt" 2>&1
RC=$?; END=$(date +%s)
grade_one "$REPO" "$OUTDIR"
echo "$RC" > "$OUTDIR/exit_code"; echo "$((END-START))" > "$OUTDIR/duration_s"
sha_of "$OUTDIR/transcript.txt" > "$OUTDIR/transcript.full.sha256"
wc -c < "$OUTDIR/transcript.txt" > "$OUTDIR/transcript.bytes"
echo "[nugget t$TRIAL] rc=$RC dur=$((END-START))s grade=$(cat $OUTDIR/grade.json) sha=$(cat $OUTDIR/transcript.full.sha256)"
