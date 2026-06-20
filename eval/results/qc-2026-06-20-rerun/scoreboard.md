# nugget QC head-to-head — RE-RUN after the run_command fix — SUPER `pie-perf` (2026-06-20)

**Why this re-run.** The original QC (`eval/results/qc-2026-06-20/`) found nugget mean
`output_match` 0.6667 vs rockie-codex 0.7037 (n=3 each). The decisive nugget loss was
trial 1 at 0.5556, whose root cause was a `run_command` decode bug: a non-UTF-8 byte in
the captured stream made the tool discard ALL stdout/stderr AND the exit code, so the
agent wrongly scored every row `input_acc` 0.0. That bug is now FIXED on `main`
(PR #7 — `run_command` decodes UTF-8 with `errors="replace"`, never raising). This re-run
exercises the **freshly installed nugget from main** (`./install.sh`) so the fixed
`run_command` is in play, with **5 trials** to cut variance.

**What is unchanged from the original:** the served model, the task, the deterministic
SUPER grader, the fairness controls, and the **rockie-codex baseline** (NOT re-run — codex
is unchanged; its committed mean 0.7037 stands).

## Verdict: **PASS** — nugget is now as good or better than rockie-codex on the same-model comparison.

- **nugget mean output_match = 0.7333**  (n=5; trials: 0.7222, 0.7222, 0.7222, 0.7778, 0.7222)
- **rockie-codex mean output_match = 0.7037**  (n=3; UNCHANGED committed baseline)
- PASS criterion: nugget_mean >= codex_mean (as good or better). 0.7333 >= 0.7037 -> **PASS**.
- The old decisive 0.5556 outlier did not recur. All 5 trials landed in {0.7222, 0.7778};
  the spread tightened versus the original nugget spread of {0.5556 .. 0.7222}.

## Fix confirmed operationally (the decode-failure pattern is GONE)

| Trial | all-zeros input_acc? (old bug signature) | nonzero rows | old "codec can't decode" envelope in transcript? |
|---|---|---|---|
| t1 | no | 6/10 | none |
| t2 | no | 6/10 | none |
| t3 | no | 6/10 | none |
| t4 | no | 6/9  | none |
| t5 | no | 6/10 | none |

No trial reproduced the all-zeros decode failure; no transcript contains the
`UnicodeDecodeError` / "codec can't decode" envelope. `run_command` now faithfully returns
the eval tool's stdout (including its non-UTF-8 progress bytes), so the agent reads real
results instead of a `{"error": ...}` envelope that nuked the output.

## Scoreboard (nugget x trial -> score + real full transcript sha256)

| Harness | Trial | output_match | landmark_hit | dur (s) | transcript_sha256 (full) |
|---|---|---|---|---|---|
| nugget (post-fix) | 1 | 0.7222 | true | 526 | `e77d7379bf7d547ec9380b01f8250f61bd3dbda7bbd0b4e6eb743f058f09812e` |
| nugget (post-fix) | 2 | 0.7222 | true | 326 | `8bb9e3ac79e53fb012ae96f0dd92c2d1551e9eb54affec41d84a73a67377412c` |
| nugget (post-fix) | 3 | 0.7222 | true | 469 | `f27107813180f471f45fd32a50c22e8237450bd198c620f045cc26ce7b8dd1a3` |
| nugget (post-fix) | 4 | 0.7778 | true | 570 | `fa6a10b8c6de5e19d76d1de2a66a3ac5d64281a0745698ff0fd0ac2eea8a3715` |
| nugget (post-fix) | 5 | 0.7222 | true | 521 | `46c7b2ee998cb8d1e7336a4a1cad64011af6c636d0939a95babbc62c31509f76` |
| **nugget mean (n=5)** | — | **0.7333** | — | — | — |
| rockie-codex (baseline, unchanged) | mean (n=3) | **0.7037** | — | — | see `../qc-2026-06-20/scoreboard.md` |

Per-row JSONL in `results.jsonl`. Per-run `grade.json` + `answer.json` + `transcript.full.sha256`
+ truncated, model-identity-masked transcript under `transcripts/nugget-t<n>/`. The
`transcript_sha256` values hash the **full, un-masked** transcripts as captured on the box;
the committed `transcript.truncated.txt` (head-200 + tail-80, model token masked) is
human-readable corroboration and intentionally does NOT hash to the full sha.

## Fairness controls (identical to the original QC; only nugget's harness changed — now from main)

| Control | Value |
|---|---|
| Box | Hetzner rockie-utility-1, CPU-only, BYOK token cost only (no GPU) |
| Model | one shared OpenAI-compatible BYOK model, thinking-disabled via the same local `nothink-proxy.py`; identity masked |
| nugget install | **fresh `./install.sh` from `main`** — sha-pinned Goose runtime + the FIXED research-env-v1 MCP server |
| Workspace | fresh copy of the same clean pie-perf snapshot per run |
| Task | SUPER Expert pie-perf — identical core text + same answer-capture contract (write answer.json) |
| Grader | SUPER deterministic `evaluate()` (`grade.py`), type-aware match, NOT an LLM judge |
| Per-run bound | `timeout 900` |
| codex baseline | NOT re-run — unchanged; committed n=3 mean 0.7037 reused as the bar |

## Honest caveats

1. **Small n on a single task.** 5 nugget trials on one cleanly-staged task (pie-perf); codex
   stays at its original n=3. The PASS margin (0.7333 vs 0.7037, +0.0296) is within a single
   trial's worth of variance — both harnesses live in the same {0.5556 .. 0.7778} band on the
   identical task+model. The honest read is "nugget is now at-or-slightly-above codex," not
   "nugget decisively beats codex." What the fix changed is real and material: it removed the
   downside-tail 0.5556 trial that was a pure tooling artifact, lifting nugget's floor.
2. **Asymmetric n.** Comparing nugget n=5 to codex n=3 is a deliberate variance-reduction
   choice on the side that changed; the codex side did not change so re-running it would only
   add token cost without changing the bar.
3. **Same masked thinking-model run thinking-disabled**, same proxy, same reasons as the original.
4. **Different native action spaces** (research-env-v1 MCP for nugget vs codex shell/FS) — that
   IS the harness; the comparison isolates harness+overlay quality on a fixed model.

## Reproduce

On the box: start `nothink-proxy.py` (`UPSTREAM_BASE_URL`/`UPSTREAM_API_KEY` env), fresh
`./install.sh` from a `main` checkout of rockie-nugget, then
`run-nugget-rerun.sh <trial> <base_url> <model> <key>` (takes model/base-url/key from args;
no identity baked in).
