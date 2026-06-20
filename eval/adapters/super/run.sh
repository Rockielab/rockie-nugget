#!/usr/bin/env bash
# run.sh — drive the SUPER pie-perf task through OUR harness (Goose + research-env-v1 + your model).
#
# Integration principle: we use SUPER's task + grader, but the SCAFFOLD is OURS.
# Goose runs with the research-env-v1 MCP extension (our 9-tool action space) mounted,
# its FS/shell tools sandboxed to the staged task workspace. We do NOT use SUPER's native agent.
#
# Env required (bring your own OpenAI-compatible endpoint):
#   OPENAI_API_KEY     (injected inline; never persisted on the box)
#   OPENAI_BASE_URL    (your provider's OpenAI-compatible base URL)
#   GOOSE_MODEL        (the model name your provider exposes)
# Outputs (in $WORKSPACE/repo):
#   answer.json        — the agent's final reported result (written via our write_file tool)
#   transcript.txt     — full goose transcript
set -euo pipefail

WORKSPACE="${WORKSPACE:-/tmp/super-pie-perf-ws}"
REPO="$WORKSPACE/repo"
GOOSE="${GOOSE:-goose}"  # path to your built goose binary, or just `goose` if on PATH
CONFIG="$HOME/.config/goose/config.yaml"
: "${OPENAI_API_KEY:?set OPENAI_API_KEY inline}"
: "${OPENAI_BASE_URL:?set OPENAI_BASE_URL to your OpenAI-compatible endpoint}"
: "${GOOSE_MODEL:?set GOOSE_MODEL to the model name your provider exposes}"

# Point our research-env-v1 MCP server's workspace at the staged task repo.
# (Server reads RESEARCH_ENV_WORKSPACE at startup; goose spawns it per-run from config.yaml.)
python3 - "$CONFIG" "$REPO" <<'PY'
import sys, re
cfg, ws = sys.argv[1], sys.argv[2]
t = open(cfg).read()
t = re.sub(r'RESEARCH_ENV_WORKSPACE:.*', f'RESEARCH_ENV_WORKSPACE: {ws}', t)
open(cfg, "w").write(t)
print("[run] workspace ->", ws)
PY

# The SUPER task query, verbatim, PLUS the one harness-contract line: write the final
# JSON-list report to answer.json so the grader can pick it up. (Capture mechanism only;
# does not change what the task asks the agent to compute.)
read -r -d '' TASK <<'EOF' || true
You are evaluating a code-improvement model on the pie-perf benchmark. Use ONLY the research-env-v1 extension tools (list_files, read_file, write_file, run_command, finish). Do NOT use built-in shell/developer tools.

Task: Evaluate the generations of a code-improving model (v1 vs v0). The generations are already staged in this workspace at data/sample/generations.csv (a CSV with columns including problem_id, code_v0, code_v1, language). The repo's evaluation tool is src/codenet_eval/run_eval.py, driven by a YAML config (see data/sample/sample_eval_config.yaml for the schema). The public test cases are staged at data/codenet/public_test_cases/.

Once evaluated, report the result problem_id and input_acc for EACH evaluated row of the dataset, as a json list of dictionaries: [{"problem_id": "", "input_acc": 0.0}].

Additional instructions:
1. Set "num_trials": 2 in the evaluation configuration file to reduce computation time.
2. Load only the first 10 rows of the dataset.

When done, write your final json-list report to answer.json using write_file, then call finish.
EOF

cd "$REPO"
echo "[run] launching goose ($GOOSE_MODEL) on pie-perf via research-env-v1 ..."
env OPENAI_API_KEY="$OPENAI_API_KEY" \
    OPENAI_BASE_URL="$OPENAI_BASE_URL" \
    GOOSE_PROVIDER="${GOOSE_PROVIDER:-openai}" \
    GOOSE_MODEL="$GOOSE_MODEL" \
  "$GOOSE" run --no-session -t "$TASK" 2>&1 | tee "$REPO/transcript.txt"

echo "[run] DONE. answer at $REPO/answer.json ; transcript at $REPO/transcript.txt"
