#!/usr/bin/env python3
"""SUPER grader for the first-adapter slice.

Reads the answer our harness produced (answer.json in the task workspace) and
scores it against the SUPER task's gold `answer` using SUPER's OWN deterministic
`evaluate()` function (vendored verbatim from allenai/super-benchmark
super/evaluate_dataset.py @ main). NOT an LLM-judge: type-aware exact/numeric match.

Usage:
  grade.py --task task.json --answer /path/to/answer.json
Emits a JSON line: {"task_id":..., "output_match": <float 0..1>, ...}
"""
import argparse
import json
import sys


# ---- vendored verbatim from allenai/super-benchmark super/evaluate_dataset.py ----
def evaluate(predicted, gold, float_epsilon: float = 1e-2) -> float:
    if type(gold) == int:
        gold = float(gold)
    if type(predicted) == int:
        predicted = float(predicted)

    if type(gold) != type(predicted):
        return 0.0

    if type(gold) == list:
        if len(gold) == 0:
            raise ValueError("Gold is empty")
        return sum([evaluate(p, g) for p, g in zip(predicted, gold)]) / len(gold)

    if type(gold) == dict:
        if len(gold) == 0:
            raise ValueError("Gold is empty")
        return sum(
            [evaluate(gv, predicted.get(gk, None), float_epsilon=float_epsilon) for gk, gv in gold.items()]
        ) / len(gold)

    if type(gold) == str:
        return float(predicted.strip() == gold.strip())

    if type(gold) == float:
        return float(abs(predicted - gold) < float_epsilon)

    raise NotImplementedError
# ---- end vendored ----


def coerce_answer(raw):
    """The harness may write the answer as a bare JSON list, or wrapped in prose.
    Pull the first top-level JSON array/object out of the text."""
    raw = raw.strip()
    try:
        return json.loads(raw)
    except Exception:
        pass
    # salvage: find first '[' .. matching ']' (the report is a json list)
    start = raw.find("[")
    if start != -1:
        depth = 0
        for i in range(start, len(raw)):
            if raw[i] == "[":
                depth += 1
            elif raw[i] == "]":
                depth -= 1
                if depth == 0:
                    return json.loads(raw[start : i + 1])
    raise ValueError("could not parse a JSON answer from the harness output")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True, help="path to task.json")
    ap.add_argument("--answer", required=True, help="path to harness-written answer.json")
    args = ap.parse_args()

    task = json.load(open(args.task))
    gold = json.loads(task["answer"])

    answer_text = open(args.answer).read()
    try:
        predicted = coerce_answer(answer_text)
    except Exception as e:
        out = {"task_id": task["task_id"], "output_match": 0.0, "error": f"unparseable answer: {e}"}
        print(json.dumps(out))
        sys.exit(0)

    try:
        score = evaluate(predicted, gold)
    except Exception as e:
        out = {"task_id": task["task_id"], "output_match": 0.0, "error": f"evaluate() failed: {e}"}
        print(json.dumps(out))
        sys.exit(0)

    out = {
        "task_id": task["task_id"],
        "benchmark": task["benchmark"],
        "subset": task["subset"],
        "output_match": round(score, 4),
        "predicted": predicted,
        "gold": gold,
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
