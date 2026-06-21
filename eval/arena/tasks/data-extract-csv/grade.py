#!/usr/bin/env python3
"""Deterministic grader for data-extract-csv — exact output match.

Recomputes the correct region->total-revenue map from the SAME sales.csv that
prepare.sh staged (oracle and fixture cannot drift), then scores the agent's
answer.json: a key is "correct" iff present with a value within 1e-6 of the gold.
output_match = correct_keys / total_gold_keys, with a penalty if the agent emits
EXTRA (spurious) keys. No LLM judge.

Usage: grade.py --task task.json --answer /path/to/answer.json --workspace /path/to/ws
"""
import argparse
import csv
import json
import os
import sys


def gold_from_csv(csv_path):
    totals = {}
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            r = row["region"].strip()
            totals[r] = totals.get(r, 0.0) + float(row["revenue"])
    return totals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True)
    ap.add_argument("--answer", required=True)
    ap.add_argument("--workspace", required=True,
                    help="staged workspace dir (contains sales.csv) — the grader's oracle source")
    args = ap.parse_args()
    task = json.load(open(args.task))
    tid = task["task_id"]

    csv_path = os.path.join(args.workspace, "sales.csv")
    gold = gold_from_csv(csv_path)
    total = len(gold)

    try:
        pred = json.load(open(args.answer))
        if not isinstance(pred, dict):
            raise ValueError("answer.json is not a JSON object")
    except Exception as e:
        print(json.dumps({"task_id": tid, "output_match": 0.0,
                          "error": f"unparseable answer: {e}"}))
        sys.exit(0)

    correct = 0
    for k, gv in gold.items():
        if k in pred:
            try:
                if abs(float(pred[k]) - gv) < 1e-6:
                    correct += 1
            except Exception:
                pass
    extra = [k for k in pred if k not in gold]
    score = correct / total
    if extra:  # spurious keys are wrong output; cap a perfect score
        score = min(score, (total - len(extra)) / total) if total else 0.0
        score = max(score, 0.0)

    print(json.dumps({"task_id": tid, "grading": "output-match",
                      "correct_keys": correct, "total_keys": total,
                      "extra_keys": extra,
                      "output_match": round(score, 4)}))


if __name__ == "__main__":
    main()
