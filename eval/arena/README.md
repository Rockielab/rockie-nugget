# nugget Model Arena — multi-task, deterministic-graded suite

A rigorous Model Arena needs **more than one task** and **deterministic grading** so
model comparisons are trustworthy. This directory generalizes the single-task SUPER
`pie-perf` adapter (`../adapters/super/`) into a **multi-task suite** driven by a single
runner, every task graded by an objective grader (unit-test-pass / output-match) — **never
an LLM judge**.

## Principle (scaffold-confound discipline)

The **harness is fixed**: nugget = `goose` + the `research-env-v1` MCP action space
(`list_files / read_file / write_file / run_command / finish`). Only the **model** varies,
supplied at run time via generic env (`OPENAI_BASE_URL / OPENAI_API_KEY / GOOSE_MODEL`).
Every model sees the **same freshly-staged workspace** per task, the **same prompt**, and
the **same deterministic grader**. We measure *a model in our harness*, not a benchmark's
native agent.

## The tasks

| task | kind | grading method | answer artifact |
|------|------|----------------|-----------------|
| `algo-twosum` | algorithmic coding | **unit-test-pass** — hidden battery imports `two_sum` and checks each result is a valid index pair summing to target | `solution.py` |
| `algo-anagram-groups` | algorithmic coding | **unit-test-pass** — hidden battery imports `group_anagrams`, checks the canonical grouping (order-independent) is exactly correct | `solution.py` |
| `data-extract-csv` | data extraction | **output-match** — grader recomputes the gold region→revenue map from the *same staged* `sales.csv`, compares numerically (1e-6), penalizes spurious keys | `answer.json` |
| `fix-failing-test` | debugging | **unit-test-pass** — buggy `roman.py` + a failing pytest suite; grader runs an *independent hidden* `to_roman` battery (can't be gamed by editing the visible suite) | `roman.py` |
| `super-pie-perf` *(optional)* | research benchmark | **output-match** — SUPER's own `evaluate()` (vendored verbatim), via `../adapters/super/grade.py` | `answer.json` |

Each non-SUPER task is a self-contained `tasks/<id>/` dir with three thin files:
- `task.json` — task id, grading method, the agent prompt, the answer artifact name.
- `prepare.sh` — stages a deterministic, self-contained workspace (`WORKSPACE=<dir> bash prepare.sh`). The fixture *is* the oracle source where relevant, so they can't drift.
- `grade.py` — deterministic grader, emits `{"output_match": <0..1>, ...}` JSON.

`super-pie-perf` is **optional** in the runner because it needs Google-Drive inputs staged
out of band; include it by pre-staging the pie-perf snapshot and exporting
`PIE_PERF_SNAPSHOT=<dir>` plus `ARENA_TASKS="... super-pie-perf"`.

## Run it

```bash
# one model (label is yours; choose a generic label if you'll share results)
OPENAI_BASE_URL=<your-openai-compatible-endpoint> \
OPENAI_API_KEY=<key-injected-inline> \
GOOSE_MODEL=<model-your-endpoint-exposes> \
MODEL_LABEL=model-a \
GOOSE=/path/to/nugget/bin/goose \
bash run-arena.sh
```

A full slate (e.g. with an OpenRouter key later) "just works" via a **private** slate file —
one `label<TAB>base_url<TAB>model<TAB>api_key` line per model:

```bash
ARENA_SLATE=/root/arena-slate.tsv GOOSE=/path/to/goose bash run-arena.sh
```

> **The slate file names models + carries keys — keep it PRIVATE (e.g. `/root/`, `/tmp/`).**
> It is read at run time and never committed. The committed runner reads the model only
> from env; no provider or model name lives in this repo.

## Output

Per model under `$ARENA_OUT/<label>/`:
- `results.jsonl` — one line per task: `model_label`, `task_id`, `output_match`, `duration_s`,
  `exit_code`, the full grader JSON, and the transcript SHA. **Labels only — never the model name.**
- `scoreboard.md` — mean `output_match` across tasks + a per-task breakdown.

If more than one label ran, a cross-model summary prints at the end.

## Masking (hard rule)

The **tasks + runner are generic** → committed publicly. Any **arena RESULTS that name
models** stay private (off-repo). Pre-push, this must be empty (except a smoke-test guard):

```bash
grep -rinE 'deepseek|stone-?1|stone1|api\.deepseek|deepseek-chat|glm|qwen|kimi|moonshot' eval/arena/
```
