#!/usr/bin/env python3
"""Deterministic grader for fix-failing-test — HIDDEN to_roman battery.

Imports the agent-fixed roman.to_roman and runs an INDEPENDENT hidden battery
(distinct from the visible test_roman.py, so editing the visible suite can't win).
output_match = fraction of hidden cases passing. No LLM judge.

Usage: grade.py --task task.json --answer /path/to/roman.py
"""
import argparse
import importlib.util
import json
import sys

# Hidden cases (n -> expected roman). Distinct/expanded from the visible suite.
HIDDEN = {
    1: "I", 3: "III", 4: "IV", 8: "VIII", 9: "IX", 14: "XIV", 19: "XIX",
    40: "XL", 44: "XLIV", 49: "XLIX", 90: "XC", 99: "XCIX", 400: "CD",
    444: "CDXLIV", 900: "CM", 949: "CMXLIX", 1000: "M", 1984: "MCMLXXXIV",
    1994: "MCMXCIV", 2024: "MMXXIV", 2888: "MMDCCCLXXXVIII", 3549: "MMMDXLIX",
    3999: "MMMCMXCIX",
}


def load_fn(path):
    spec = importlib.util.spec_from_file_location("agent_roman", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return getattr(mod, "to_roman")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True)
    ap.add_argument("--answer", required=True)
    args = ap.parse_args()
    task = json.load(open(args.task))
    tid = task["task_id"]
    try:
        fn = load_fn(args.answer)
    except Exception as e:
        print(json.dumps({"task_id": tid, "output_match": 0.0,
                          "error": f"could not load roman.py: {e}"}))
        sys.exit(0)
    passed = 0
    for n, exp in HIDDEN.items():
        try:
            if fn(n) == exp:
                passed += 1
        except Exception:
            pass
    total = len(HIDDEN)
    print(json.dumps({"task_id": tid, "grading": "unit-test-pass",
                      "passed": passed, "total": total,
                      "output_match": round(passed / total, 4)}))


if __name__ == "__main__":
    main()
