#!/usr/bin/env python3
"""Deterministic grader for algo-anagram-groups — HIDDEN unit-test battery.

Loads solution.group_anagrams, runs hidden cases, checks the grouping is correct.
Correctness is order-tolerant on the OUTER group order only insofar as the spec
allows; we verify the canonical grouping (set of sorted groups) is exactly right,
which is the load-bearing property. output_match = fraction passed. No LLM judge.
"""
import argparse
import importlib.util
import json
import sys

HIDDEN_TESTS = [
    ["eat", "tea", "tan", "ate", "nat", "bat"],
    [""],
    ["a"],
    ["abc", "bca", "cab", "xyz", "zyx", "foo"],
    ["listen", "silent", "enlist", "google", "banana"],
    ["ab", "ba", "abc", "cba", "bca", "ab"],
    ["rat", "tar", "art", "star", "tars", "rats"],
    ["one", "neo", "eon", "two", "ten", "net"],
]


def expected_grouping(words):
    """Canonical correct grouping: map sorted-chars -> list of words (input order)."""
    buckets = {}
    order = []
    for w in words:
        k = "".join(sorted(w))
        if k not in buckets:
            buckets[k] = []
            order.append(k)
        buckets[k].append(w)
    return [buckets[k] for k in order]


def canonical(groups):
    """Order-independent canonical form: frozenset of sorted-tuple groups (with multiplicity)."""
    if not isinstance(groups, (list, tuple)):
        return None
    norm = []
    for g in groups:
        if not isinstance(g, (list, tuple)):
            return None
        norm.append(tuple(sorted(g)))
    # multiset of groups
    return tuple(sorted(norm))


def load_fn(path):
    spec = importlib.util.spec_from_file_location("agent_solution", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return getattr(mod, "group_anagrams")


def check(fn, words):
    try:
        got = fn(list(words))
    except Exception:
        return False
    exp = expected_grouping(words)
    return canonical(got) == canonical(exp)


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
                          "error": f"could not load solution: {e}"}))
        sys.exit(0)
    passed = sum(1 for w in HIDDEN_TESTS if check(fn, w))
    total = len(HIDDEN_TESTS)
    print(json.dumps({"task_id": tid, "grading": "unit-test-pass",
                      "passed": passed, "total": total,
                      "output_match": round(passed / total, 4)}))


if __name__ == "__main__":
    main()
