#!/usr/bin/env bash
# prepare.sh — stage the algo-twosum workspace (deterministic, self-contained).
# The agent writes solution.py to the workspace root; grade.py runs hidden unit tests.
set -euo pipefail
WORKSPACE="${WORKSPACE:?set WORKSPACE to the staging dir}"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
# A README in the workspace so the agent has the spec on disk too (matches the prompt).
cat > "$WORKSPACE/README.md" <<'EOF'
# two_sum

Implement `def two_sum(nums, target):` in solution.py (workspace root).
Return [i, j] with i < j and nums[i] + nums[j] == target. Exactly one pair exists.
EOF
echo "[prepare:algo-twosum] staged $WORKSPACE"
