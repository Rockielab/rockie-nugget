#!/usr/bin/env bash
# prepare.sh — stage the data-extract-csv workspace (deterministic, self-contained).
# Writes a fixed sales.csv. The grader recomputes the gold from this same file,
# so the fixture and the oracle can never drift.
set -euo pipefail
WORKSPACE="${WORKSPACE:?set WORKSPACE to the staging dir}"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
cat > "$WORKSPACE/sales.csv" <<'EOF'
region,product,units,revenue
east,widget,10,100.50
west,widget,5,52.25
east,gadget,3,45.00
north,widget,8,80.00
west,gadget,2,30.00
east,widget,1,10.50
south,gizmo,7,77.77
north,gadget,4,44.40
west,gizmo,6,61.20
south,widget,9,90.00
EOF
echo "[prepare:data-extract-csv] staged $WORKSPACE (sales.csv $(wc -l < "$WORKSPACE/sales.csv") lines)"
