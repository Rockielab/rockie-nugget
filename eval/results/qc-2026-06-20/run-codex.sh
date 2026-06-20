#!/usr/bin/env bash
# run-codex.sh <trial> <base_url> <model> <api_key>
# rockie-codex = official codex binary + AGENTS.md overlay. SAME model via OpenAI-compat provider.
set -uo pipefail
source /root/nugget-qc-2026-06-20/qc-lib.sh
TRIAL="$1"; BASE_URL="$2"; MODEL="$3"; API_KEY="$4"
CODEX=/usr/local/bin/codex042
LABEL="codex-t$TRIAL"
OUTDIR="$RES/$LABEL"; mkdir -p "$OUTDIR"
REPO=$(stage_ws "$LABEL")

# Install the rockie-codex overlay into the workspace (AGENTS.md = the codex ethos overlay).
cp /root/nugget-qc-2026-06-20/overlays/codex-AGENTS.md "$REPO/AGENTS.md"

# Per-run isolated CODEX_HOME with an OpenAI-compatible provider.
CXH="$QC/ws/$LABEL/codex-home"; mkdir -p "$CXH"
cat > "$CXH/config.toml" <<TOML
model = "$MODEL"
model_provider = "shared"
[model_providers.shared]
name = "shared-openai-compat"
base_url = "$BASE_URL"
env_key = "OPENAI_API_KEY"
wire_api = "chat"
TOML

# codex-native tool instruction (its native shell/FS action space) + identical core task
TASK="You are evaluating a code-improvement model on the pie-perf benchmark. Use your shell and file tools to do the work in the current workspace.

$(core_task)

Write your final json-list report to a file named answer.json in the workspace root, then stop."

cd "$REPO"
START=$(date +%s)
env OPENAI_API_KEY="$API_KEY" CODEX_HOME="$CXH" \
  timeout "$PER_RUN_TIMEOUT" "$CODEX" exec \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check -C "$REPO" -m "$MODEL" \
    "$TASK" > "$OUTDIR/transcript.txt" 2>&1
RC=$?; END=$(date +%s)
grade_one "$REPO" "$OUTDIR"
echo "$RC" > "$OUTDIR/exit_code"; echo "$((END-START))" > "$OUTDIR/duration_s"
sha_of "$OUTDIR/transcript.txt" > "$OUTDIR/transcript.sha256"
echo "[codex t$TRIAL] rc=$RC dur=$((END-START))s grade=$(cat $OUTDIR/grade.json) sha=$(cat $OUTDIR/transcript.sha256)"
