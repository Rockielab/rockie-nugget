# nugget QC head-to-head — SUPER `pie-perf` (2026-06-20)

**Claim under test (design `nugget-parity-overlay-2026-06-20.md` §5 / slice H):**
"nugget is as good or better than rockie-codex (and rockie-claude) on real research
tasks." PASS = nugget mean `output_match` >= max(others) on the same-model comparison,
every row backed by a real `transcript_sha256` of a non-empty transcript, `landmark_hit`
true. The grader is deterministic (SUPER's own `evaluate()`), never self-graded (#833).

## Verdict: **FAIL (narrow)** on the strict criterion — nugget mean < codex mean by one stochastic trial.

- **nugget mean output_match = 0.6667**  (trials: 0.5556, 0.7222, 0.7222)
- **rockie-codex mean output_match = 0.7037**  (trials: 0.7778, 0.7778, 0.5556)
- PASS needs nugget_mean >= codex_mean; 0.6667 < 0.7037 → **FAIL**, but the gap (0.0370)
  is smaller than one trial's worth of variance — both harnesses span the same
  {0.5556 .. 0.7778} band on the identical task+model. This is "roughly at parity,
  codex nominally ahead," not "nugget is worse."

## Fairness controls (the only variable is the harness/overlay)

| Control | Value (identical across all runs) |
|---|---|
| Box | Hetzner rockie-utility-1, CPU-only, BYOK token cost only (no GPU) |
| Model | one shared OpenAI-compatible BYOK model, **thinking-disabled** via a local passthrough proxy (`nothink-proxy.py`); identity masked |
| Why the proxy | the shared model is a *thinking* model; both goose and codex 0.42's OpenAI clients 400 on multi-turn tool calls ("`reasoning_content` must be passed back"). The proxy injects `{"thinking":{"type":"disabled"}}` so BOTH harnesses drive the same model cleanly. Same fix for both → fair. |
| Workspace | fresh copy of one clean pie-perf snapshot per run (no cross-run contamination) |
| Task | SUPER Expert pie-perf — identical core text; only the tool-instruction line names each harness's native action space (research-env-v1 MCP for nugget; shell/FS for codex) |
| Grader | SUPER's deterministic `evaluate()` (`grade.py`), type-aware match, NOT an LLM judge |
| Per-run bound | `timeout 900` |
| Overlay | nugget runs WITH its `overlay/goosehints`; codex runs WITH the `rockie-codex` `AGENTS.md` overlay |

## Scoreboard (harness × trial → score + real transcript sha256)

| Harness | Trial | output_match | landmark_hit | dur (s) | transcript_sha256 (full) |
|---|---|---|---|---|---|
| nugget | 1 | 0.5556 | true | 239 | `6f4523b4dec0e5cf6d6883a87c3b41d9ce4fc29c0dff3fe90fc0806acd26add7` |
| nugget | 2 | 0.7222 | true | 277 | `2e8cbf02a2a10ee4612334ae46d7c7c6d07edee91c7fc808b5b24d82d1268420` |
| nugget | 3 | 0.7222 | true | 201 | `50f5eeb40cb613a6c0d28be3ebc6fb154d80d06a2414812d26eb89d8aced82cb` |
| **nugget mean** | — | **0.6667** | — | — | — |
| rockie-codex | 1 | 0.7778 | true | 241 | `7fe0538fbac4eccf8cc81f7dd7875ddbbe2f6112cb0daa4783142fa164a943fd` |
| rockie-codex | 2 | 0.7778 | true | 490 | `55624f875e86477c2d5f887c20212e85ea7592d597b4713bb5a1b54b24850ca4` |
| rockie-codex | 3 | 0.5556 | true | 269 | `d57a52b3ee3c237537269e7e2466d9c41e9672e0b892ed3829dd97918618508c` |
| **rockie-codex mean** | — | **0.7037** | — | — | — |

Per-row JSONL in `results.jsonl`; per-run `grade.json` + `answer.json` + truncated
transcript under `transcripts/<harness>-t<n>/`. The `transcript_sha256` values above are
of the **full, un-masked** transcripts as captured on the box (each `transcript.full.sha256`
file repeats its run's value). The committed `transcript.truncated.txt` copies are
head-200 + tail-80 with the shared-model identity token masked (the masking boundary) —
so the committed truncated text intentionally does NOT hash to the full sha; the full sha
is the evidence the run happened, the truncated text is human-readable corroboration.

## Same-model vs not

- **nugget vs rockie-codex = clean SAME-model comparison.** Both drove the identical
  shared OpenAI-compatible model through the same proxy. This is the core deliverable.
- **rockie-claude = NOT run.** Claude Code is Anthropic-native; the shared OpenAI-compatible
  model is not usable without an OpenAI→Anthropic Messages-API translation gateway, which
  is not trivially available and would be substantial bespoke harness code (slop) — and
  even then Claude Code validates model ids against Anthropic's catalog. Running it on its
  own native Anthropic model would require a paid Anthropic account (out of scope: no new
  paid accounts) AND would not be a same-model comparison. Per the design's stated fallback
  ("if not feasible cleanly, DOCUMENT why"), rockie-claude is documented as omitted rather
  than faked. A genuine claude same-model leg is future work gated on a trivial
  Anthropic-shaped gateway + an Anthropic key.

## Honest caveats

1. **Single task, 3 trials each.** Only pie-perf is cleanly staged on the box; the other
   SUPER Expert tasks need their own repos/gdrive inputs + answer keys that are not present.
   Padding to 3 fake tasks would violate honesty (#833), so the variance is addressed via
   3 trials on the one real task, not fake task diversity. n=3 per harness is small — the
   0.037 mean gap is well inside trial noise.
2. **Model is a thinking model run thinking-disabled.** Required so both harnesses can
   multi-turn at all. A non-thinking shared model would remove the proxy; the comparison
   would be unchanged in spirit.
3. **Different native action spaces.** nugget acts through the research-env-v1 MCP tools;
   codex acts through its own shell/FS tools. That IS the harness — the comparison isolates
   harness+overlay quality on a fixed model, which is the intended variable.

## Reproduce

On the box: start `nothink-proxy.py` (`UPSTREAM_BASE_URL`/`UPSTREAM_API_KEY` env), then
`run-nugget.sh <trial> <base_url> <model> <key>` and `run-codex.sh <trial> <base_url>
<model> <key>` (codex uses the 0.42 binary — 0.141 dropped `wire_api=chat`). All scripts
take model/base-url/key from args/env; no identity is baked in.
