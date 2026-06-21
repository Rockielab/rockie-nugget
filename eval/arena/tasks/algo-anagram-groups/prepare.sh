#!/usr/bin/env bash
# prepare.sh — stage the algo-anagram-groups workspace (deterministic, self-contained).
set -euo pipefail
WORKSPACE="${WORKSPACE:?set WORKSPACE to the staging dir}"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
cat > "$WORKSPACE/README.md" <<'EOF'
# group_anagrams

Implement `def group_anagrams(words):` in solution.py (workspace root).
Group anagrams together; preserve in-group input order; order groups by first appearance.
EOF
echo "[prepare:algo-anagram-groups] staged $WORKSPACE"
