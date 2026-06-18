#!/usr/bin/env bash
# prepare.sh — stage the SUPER pie-perf task workspace.
# Adapter responsibility = OBTAIN benchmark inputs. The HARNESS does the actual eval work.
#
# Stages into $WORKSPACE:
#   - the pie-perf repo @ pinned commit (the task's tooling: src/codenet_eval/run_eval.py)
#   - generations.csv      (gdrive: the v1-vs-v0 model outputs to evaluate)
#   - data/codenet/public_test_cases/  (gdrive: test inputs/outputs run_eval needs)
# Idempotent: re-running re-stages cleanly.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/tmp/super-pie-perf-ws}"
VENV="${VENV:-/tmp/superenv}"                      # has gdown installed
GEN_ID="1izs1iF5cd_NAZsOaZvrrQF3NAsoP8lHf"
TC_ID="1RcUpZMOR8L2xYYWDZx7I0tHFzFgg7COO"
COMMIT="ee1989b66756470622e3b89c4aa031f083f57ef9"

echo "[prepare] workspace=$WORKSPACE"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo "[prepare] cloning pie-perf @ $COMMIT"
git clone -q https://github.com/madaan/pie-perf repo
git -C repo checkout -q "$COMMIT"

echo "[prepare] downloading generations CSV (gdrive $GEN_ID)"
"$VENV/bin/gdown" "$GEN_ID" -O repo/data/sample/generations.csv -q

echo "[prepare] downloading + unpacking public test cases (gdrive $TC_ID)"
"$VENV/bin/gdown" "$TC_ID" -O /tmp/ptc.zip -q
unzip -q -o /tmp/ptc.zip -d /tmp/ptc_extract
# the zip contains codenet/public_test_cases/<problem_id>/...
mkdir -p repo/data/codenet
rm -rf repo/data/codenet/public_test_cases
mv /tmp/ptc_extract/codenet/public_test_cases repo/data/codenet/public_test_cases
rm -rf /tmp/ptc_extract /tmp/ptc.zip

# pie-perf's run_eval.py runs under the HARNESS's run_command (system python3).
# Provision its CPU-only deps so the harness shell can execute the eval. These are the
# task tooling's runtime deps, NOT a substitute for the agent's work (the agent still
# configures the YAML, invokes run_eval, and parses input_acc from the report).
echo "[prepare] provisioning system-python3 eval deps (CPU-only)"
if ! python3 -m pip --version >/dev/null 2>&1; then
  apt-get install -y -q python3-pip >/dev/null 2>&1 || true
fi
python3 -m pip install --break-system-packages -q pandas numpy tqdm psutil pyyaml >/dev/null 2>&1
python3 -c "import pandas,numpy,tqdm,psutil,yaml" && echo "[prepare] eval deps OK"

echo "[prepare] DONE. agent works in: $WORKSPACE/repo"
echo "[prepare] generations: $(wc -l < repo/data/sample/generations.csv) rows"
echo "[prepare] test-case problems: $(ls repo/data/codenet/public_test_cases | wc -l)"
