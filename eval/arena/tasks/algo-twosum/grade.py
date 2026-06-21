#!/usr/bin/env python3
"""Deterministic grader for algo-twosum — HIDDEN unit-test battery.

Loads the agent-written solution.py, imports two_sum, runs a fixed set of hidden
test cases, and emits output_match = (tests passed) / (total tests). No LLM judge.

Usage: grade.py --task task.json --answer /path/to/solution.py
"""
import argparse
import importlib.util
import json
import sys

# Hidden tests — NOT shown to the agent (the prompt shows only 3 trivial examples).
# Each: (nums, target, expected_pair_sorted). Exactly one valid pair per case.
HIDDEN_TESTS = [
    ([2, 7, 11, 15], 9, [0, 1]),
    ([3, 2, 4], 6, [1, 2]),
    ([3, 3], 6, [0, 1]),
    ([-1, -2, -3, -4, -5], -8, [2, 4]),
    ([0, 4, 3, 0], 0, [0, 3]),
    ([1, 5, 8, 3, 9, 2], 17, [2, 4]),
    ([10, 20, 30, 40, 50], 90, [3, 4]),
    ([5, 75, 25], 100, [1, 2]),
    ([-10, 7, 19, 3], 9, [0, 2]),
    ([1000000, 1, -999999, 2], 3, [1, 3]),
]


def load_two_sum(path):
    spec = importlib.util.spec_from_file_location("agent_solution", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return getattr(mod, "two_sum")


def check(fn, nums, target, expected):
    try:
        got = fn(list(nums), target)
    except Exception:
        return False
    if not isinstance(got, (list, tuple)) or len(got) != 2:
        return False
    try:
        i, j = int(got[0]), int(got[1])
    except Exception:
        return False
    # Accept any valid distinct pair summing to target (robust correctness check),
    # but prefer the canonical expected as a tie-break sanity assertion.
    if i == j or not (0 <= i < len(nums)) or not (0 <= j < len(nums)):
        return False
    return nums[i] + nums[j] == target


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True)
    ap.add_argument("--answer", required=True)
    args = ap.parse_args()
    task = json.load(open(args.task))
    tid = task["task_id"]

    try:
        fn = load_two_sum(args.answer)
    except Exception as e:
        print(json.dumps({"task_id": tid, "output_match": 0.0,
                          "error": f"could not load solution: {e}"}))
        sys.exit(0)

    passed = sum(1 for nums, t, exp in HIDDEN_TESTS if check(fn, nums, t, exp))
    total = len(HIDDEN_TESTS)
    print(json.dumps({"task_id": tid, "grading": "unit-test-pass",
                      "passed": passed, "total": total,
                      "output_match": round(passed / total, 4)}))


if __name__ == "__main__":
    main()
