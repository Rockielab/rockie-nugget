#!/usr/bin/env bash
# qc-lib.sh — shared fixtures for the nugget head-to-head QC.
# Same model, same workspace snapshot, same task, same grader. Only the harness varies.
set -uo pipefail
QC=/root/nugget-qc-2026-06-20
SNAP=/root/nugget-a3c/pie-perf-snapshot
GRADE="$QC/grade.py"
TASKJSON="$QC/task.json"
RES="$QC/results"
PER_RUN_TIMEOUT="${PER_RUN_TIMEOUT:-900}"

# The research task, identical in substance for every harness. Only the
# leading tool-instruction line is swapped per harness to name that harness's
# native action space (research-env-v1 MCP for nugget; shell/FS for codex/claude).
# Everything the agent must COMPUTE is identical, and the answer-capture
# contract (write answer.json) is identical.
core_task() {
cat <<'EOF'
Task: Evaluate the generations of a code-improving model (v1 vs v0). The generations are already staged in this workspace at data/sample/generations.csv (a CSV with columns including problem_id, code_v0, code_v1, language). The repo's evaluation tool is src/codenet_eval/run_eval.py, driven by a YAML config (see data/sample/sample_eval_config.yaml for the schema). The public test cases are staged at data/codenet/public_test_cases/.

Once evaluated, report the result problem_id and input_acc for EACH evaluated row of the dataset, as a json list of dictionaries: [{"problem_id": "", "input_acc": 0.0}].

Additional instructions:
1. Set "num_trials": 2 in the evaluation configuration file to reduce computation time.
2. Load only the first 10 rows of the dataset.

When done, write your final json-list report to answer.json (in the workspace root), then declare the task complete.
EOF
}

# stage a fresh identical workspace, echo the repo path
stage_ws() {
  local label="$1"
  local repo="$QC/ws/$label/repo"
  rm -rf "$QC/ws/$label"
  mkdir -p "$QC/ws/$label"
  cp -a "$SNAP" "$repo"
  echo "$repo"
}

# grade an answer.json, write grade.json, return output_match
grade_one() {
  local repo="$1" outdir="$2"
  if [ -f "$repo/answer.json" ]; then
    cp "$repo/answer.json" "$outdir/answer.json"
    python3 "$GRADE" --task "$TASKJSON" --answer "$repo/answer.json" > "$outdir/grade.json" 2>"$outdir/grade.err"
  else
    echo "{\"task_id\":\"pie-perf\",\"output_match\":0.0,\"note\":\"no answer.json written\"}" > "$outdir/grade.json"
  fi
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d" " -f1; }
