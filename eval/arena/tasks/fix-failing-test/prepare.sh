#!/usr/bin/env bash
# prepare.sh — stage the fix-failing-test workspace (deterministic, self-contained).
# Stages a roman.py with REAL bugs + a visible pytest suite that fails. The agent
# must fix roman.py. grade.py uses an independent HIDDEN battery (cannot be gamed).
set -euo pipefail
WORKSPACE="${WORKSPACE:?set WORKSPACE to the staging dir}"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"

# Buggy implementation: missing the subtractive 4/9 forms (so 4 -> "IIII", 9 -> "VIIII",
# 40 -> "XXXX", etc.). This is a real, common bug; the visible tests catch it.
cat > "$WORKSPACE/roman.py" <<'EOF'
def to_roman(n):
    if not isinstance(n, int) or n < 1 or n > 3999:
        raise ValueError("n must be an integer in 1..3999")
    # BUG: the subtractive pairs (CM, CD, XC, XL, IX, IV) are missing.
    table = [
        (1000, "M"),
        (500, "D"),
        (100, "C"),
        (50, "L"),
        (10, "X"),
        (5, "V"),
        (1, "I"),
    ]
    out = []
    for value, sym in table:
        while n >= value:
            out.append(sym)
            n -= value
    return "".join(out)
EOF

cat > "$WORKSPACE/test_roman.py" <<'EOF'
from roman import to_roman


def test_basic():
    assert to_roman(1) == "I"
    assert to_roman(2) == "II"
    assert to_roman(3) == "III"
    assert to_roman(5) == "V"
    assert to_roman(10) == "X"


def test_subtractive():
    assert to_roman(4) == "IV"
    assert to_roman(9) == "IX"
    assert to_roman(40) == "XL"
    assert to_roman(90) == "XC"
    assert to_roman(400) == "CD"
    assert to_roman(900) == "CM"


def test_composite():
    assert to_roman(14) == "XIV"
    assert to_roman(49) == "XLIX"
    assert to_roman(94) == "XCIV"
    assert to_roman(1994) == "MCMXCIV"
    assert to_roman(3888) == "MMMDCCCLXXXVIII"
    assert to_roman(3999) == "MMMCMXCIX"


if __name__ == "__main__":
    test_basic()
    test_subtractive()
    test_composite()
    print("all visible tests passed")
EOF
echo "[prepare:fix-failing-test] staged $WORKSPACE (buggy roman.py + test_roman.py)"
