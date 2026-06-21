#!/usr/bin/env bash
# run-arena.sh — multi-task nugget Model Arena runner.
#
# Runs ONE OR MORE models through nugget (goose + research-env-v1) on EVERY task
# in the suite, grades each task DETERMINISTICALLY, and emits a per-model
# scoreboard (mean across tasks + per-task breakdown).
#
# GENERIC BY CONSTRUCTION: model identity is supplied at call time via env and is
# NEVER written into a committed artifact. Two ways to drive models:
#
#   (A) Single model from env (one model per invocation):
#         OPENAI_BASE_URL=... OPENAI_API_KEY=... GOOSE_MODEL=... \
#         MODEL_LABEL=model-a bash run-arena.sh
#
#   (B) A model slate from a SLATE file (one model per line), so a full run with
#       e.g. an OpenRouter key "just works". Each non-empty, non-# line is:
#         <label>\t<base_url>\t<model_name>\t<api_key>
#       Provide via ARENA_SLATE=/path/to/slate. KEEP THE SLATE FILE PRIVATE
#       (it names models + carries keys) — it is read at runtime, never committed.
#         ARENA_SLATE=/root/arena-slate.tsv bash run-arena.sh
#
# Output: results land under $ARENA_OUT (default /tmp/nugget-arena-out). Scoreboards
# name the per-run MODEL_LABEL you supply; choose generic labels (model-a, model-b)
# if you intend to share results, so no provider/model name leaks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/arena-lib.sh"

ARENA_OUT="${ARENA_OUT:-/tmp/nugget-arena-out}"
mkdir -p "$ARENA_OUT"

run_one_model() {
  local label="$1" base_url="$2" model="$3" api_key="$4"
  echo "=== arena: model_label=$label  tasks=[$ARENA_TASKS] ===" >&2
  local results_jsonl="$ARENA_OUT/$label/results.jsonl"
  mkdir -p "$ARENA_OUT/$label"; : > "$results_jsonl"
  local sum=0 count=0
  for task in $ARENA_TASKS; do
    echo "--- [$label] task=$task ---" >&2
    local line score
    line="$(OPENAI_BASE_URL="$base_url" OPENAI_API_KEY="$api_key" GOOSE_MODEL="$model" \
            run_task_for_model "$task" "$label")"
    score="$(echo "$line" | awk '{print $2}')"
    local outdir="$ARENA_WORK/$label/$task/out"
    local dur rc; dur="$(cat "$outdir/duration_s" 2>/dev/null || echo 0)"; rc="$(cat "$outdir/exit_code" 2>/dev/null || echo -1)"
    # results.jsonl names the LABEL only — never the model/base_url/key.
    python3 - "$results_jsonl" "$task" "$label" "$score" "$dur" "$rc" "$outdir" <<'PY'
import json,sys
path,task,label,score,dur,rc,outdir=sys.argv[1:8]
grade={}
try: grade=json.load(open(f"{outdir}/grade.json"))
except Exception: pass
rec={"model_label":label,"task_id":task,"output_match":float(score),
     "duration_s":int(dur),"exit_code":int(rc),"grade":grade,
     "transcript_sha256":open(f"{outdir}/transcript.sha256").read().strip() if __import__("os").path.exists(f"{outdir}/transcript.sha256") else None}
open(path,"a").write(json.dumps(rec)+"\n")
PY
    sum="$(python3 -c "print($sum + $score)")"; count=$((count+1))
    echo "    [$label] $task -> output_match=$score (rc=$rc dur=${dur}s)" >&2
  done
  local mean; mean="$(python3 -c "print(round($sum/max($count,1),4))")"
  write_scoreboard "$label" "$mean" "$results_jsonl"
  echo "=== [$label] MEAN output_match across $count tasks = $mean ===" >&2
}

write_scoreboard() {
  local label="$1" mean="$2" results_jsonl="$3"
  local sb="$ARENA_OUT/$label/scoreboard.md"
  python3 - "$sb" "$label" "$mean" "$results_jsonl" <<'PY'
import json,sys
sb,label,mean,rj=sys.argv[1:5]
rows=[json.loads(l) for l in open(rj) if l.strip()]
with open(sb,"w") as f:
    f.write(f"# nugget Model Arena scoreboard — model_label `{label}`\n\n")
    f.write(f"**Mean output_match across {len(rows)} tasks = {mean}**\n\n")
    f.write("| task | grading | output_match | duration_s | exit |\n")
    f.write("|------|---------|-------------:|-----------:|-----:|\n")
    for r in sorted(rows,key=lambda x:x["task_id"]):
        g=r.get("grade",{}) or {}
        f.write(f"| {r['task_id']} | {g.get('grading','?')} | {r['output_match']} | {r['duration_s']} | {r['exit_code']} |\n")
    f.write("\nDeterministic graders only (unit-test-pass / output-match). No LLM judge.\n")
    f.write("Model identity is intentionally omitted — supplied via env at run time.\n")
print(sb)
PY
}

main() {
  if [ -n "${ARENA_SLATE:-}" ]; then
    [ -f "$ARENA_SLATE" ] || { echo "ARENA_SLATE not found: $ARENA_SLATE" >&2; exit 1; }
    while IFS=$'\t' read -r label base_url model api_key; do
      [ -z "$label" ] && continue
      case "$label" in \#*) continue;; esac
      run_one_model "$label" "$base_url" "$model" "$api_key"
    done < "$ARENA_SLATE"
  else
    : "${OPENAI_BASE_URL:?set OPENAI_BASE_URL (or ARENA_SLATE)}"
    : "${OPENAI_API_KEY:?set OPENAI_API_KEY inline (or ARENA_SLATE)}"
    : "${GOOSE_MODEL:?set GOOSE_MODEL (or ARENA_SLATE)}"
    run_one_model "${MODEL_LABEL:-model}" "$OPENAI_BASE_URL" "$GOOSE_MODEL" "$OPENAI_API_KEY"
  fi
  # cross-model summary if more than one label produced results
  python3 - "$ARENA_OUT" <<'PY'
import json,os,glob
out=os.environ.get("ARENA_OUT","/tmp/nugget-arena-out")
labels=[d for d in os.listdir(out) if os.path.isfile(os.path.join(out,d,"results.jsonl"))]
if len(labels)<=1: raise SystemExit
print("\n=== CROSS-MODEL SUMMARY ===")
for lab in sorted(labels):
    rows=[json.loads(l) for l in open(os.path.join(out,lab,"results.jsonl")) if l.strip()]
    if not rows: continue
    mean=round(sum(r["output_match"] for r in rows)/len(rows),4)
    print(f"  {lab}: mean={mean} (n_tasks={len(rows)})")
PY
}
main "$@"
