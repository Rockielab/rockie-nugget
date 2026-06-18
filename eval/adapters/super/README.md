# SUPER adapter — first benchmark adapter for the A5 Model Arena

Proves the **adapter pattern**: take ONE real, CPU-only research benchmark task, drive it
through **OUR harness** (Goose + DeepSeek-V3 + research-env-v1 MCP), and score it with the
**benchmark's own objective grader**. The harness is the fixed scaffold (scaffold-confound
discipline) — we measure a *model in our harness*, not the benchmark's native agent.

**Benchmark:** [SUPER](https://github.com/allenai/super-benchmark) (allenai), Apache-2.0,
publicly downloadable from HuggingFace `allenai/super` — **no gating**.
**Task:** `pie-perf` (Expert subset). Chosen because it is the lowest-friction Expert task:
pure **CPU code-execution** scoring (run generated programs against public test cases — no
model inference, no GPU, no training), and a trivially simple numeric gold answer.

## The three pieces (minimal adapter, ~3 thin files)

| file | role |
|------|------|
| `prepare.sh` | **Obtain benchmark inputs.** Clones `pie-perf` @ pinned commit, downloads the two public Google-Drive inputs the task references (model generations CSV + codenet public test cases) via `gdown`, and provisions the eval tool's CPU-only python deps. Idempotent. |
| `run.sh` | **Drive the task through OUR harness.** Points the research-env-v1 MCP workspace at the staged repo, then runs `goose run --no-session -t '<SUPER query>'` with DeepSeek-V3. The agent uses only our `list_files/read_file/write_file/run_command/finish` tools. Ends by writing `answer.json`. |
| `grade.py` | **Score with the benchmark's own grader.** Vendors SUPER's deterministic `evaluate(predicted, gold)` *verbatim* (type-aware exact/numeric match, NOT an LLM-judge) and scores `answer.json` against the task's gold `answer`. Emits `output_match` ∈ [0,1]. |
| `task.json` | The frozen task spec: query, gold `answer`, landmarks, and the gdrive input file IDs. |

## How the benchmark task maps to our harness → grader

```
SUPER task `pie-perf`
  query (verbatim)            ─┐
  + "write report to          │   goose run --no-session -t '<query>'
     answer.json" (capture)   ─┘   provider=DeepSeek-V3, ext=research-env-v1
                                          │
   workspace (staged by prepare.sh):      │   agent uses OUR tools only:
     repo/ (pie-perf tooling)             │     list_files → read_file → run_command
     repo/data/sample/generations.csv     │     (compiles+runs C++ vs test cases)
     repo/data/codenet/public_test_cases/ │     → write_file answer.json → finish
                                          ▼
                                    answer.json  (the agent's reported [{problem_id,input_acc}])
                                          │
                                    grade.py  →  SUPER evaluate(predicted, gold)
                                          ▼
                                    {"output_match": 0.7778}   ← REAL grader score
```

The only harness-specific addition to the task is a single capture line ("write your final
JSON report to answer.json"). It changes *how we read the answer back*, not *what the task
asks the model to compute*.

## Run it (CPU-only)

```bash
# 1. stage inputs (clone + gdrive downloads + eval deps)
bash prepare.sh
# 2. drive through our harness (key injected inline, never persisted)
DEEPSEEK_API_KEY=<key> bash run.sh
# 3. score with SUPER's own grader
python3 grade.py --task task.json --answer <ws>/repo/answer.json
```

## First end-to-end result

DeepSeek-V3 in our harness, graded by SUPER's `evaluate()`: **`output_match = 0.7778`**.
See `../../first-adapter-results.md` and `artifacts/` for the transcript + answer.

## Scaling to the full arena

The adapter is `(prepare, run, grade)`. To go from 1 task → all models × all benchmarks:
- **More models:** `run.sh` already parameterizes provider/model via `GOOSE_PROVIDER/GOOSE_MODEL/OPENAI_BASE_URL`. Swap those env vars; the scaffold (research-env-v1) is fixed → that's the whole point.
- **More SUPER tasks:** generalize `prepare.sh` to read `task.json`'s `gdrive_inputs` + repo/commit generically (most of it already is); the grader is task-agnostic already.
- **More benchmarks:** each new benchmark is a new `adapters/<bench>/` dir with the same 3-file contract. `grade.py` is benchmark-specific (vendor that benchmark's scorer); `run.sh` is nearly identical.
