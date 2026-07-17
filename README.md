# 🪨 rockie-nugget

**An open harness for long-horizon, autonomous AI research.**

rockie-nugget is a thin, model-agnostic agent runtime built for one job: running an AI agent
that does *real research* — reads the literature, writes code, launches GPU experiments,
reads the metrics, and iterates — for hours, unattended. It runs on your laptop, on a
server, or as a per-tenant runtime on the [Rockie](https://rockielab.com) platform.

> **Status: early, and built in the open.** The architecture below is the design we're
> building to, and parts of it are still landing. If you work on self-improving AI, agentic
> research, or research-agent evaluation, this is exactly the moment to get involved — see
> [Collaborating](#collaborating).

---

## Why another harness?

Because the harness shouldn't be the interesting part. The lesson of the last two years is
that elaborate agent scaffolding gets obsoleted by better models — so rockie-nugget keeps the
loop **deliberately thin** and puts the leverage where it lasts:

- **Model-agnostic.** Point it at any OpenAI-compatible endpoint — a frontier model, a
  cheap open-weight model, or your own local server. Bring your own key.
- **MCP-native.** Tools are [Model Context Protocol](https://modelcontextprotocol.io)
  servers. The agent's whole capability set is a declarative, versioned tool contract —
  see [`contract/`](./contract/research-env-v1/).
- **Skills are just markdown.** The Rockie skills ecosystem is plain `.md` files — read
  them, fork them, write your own. No DSL, no lock-in. ~300 of them sit behind the
  `rockie` CLI, deliberately *out* of the agent's context until it pulls one:
  `rockie skill catalog --search grpo --json`, then `rockie skill pull grpo-rl-training
  --out ./skills/grpo-rl-training`, then read it. The `find-skills.yaml` recipe drives
  that loop; the CLI is optional and nugget works fine without it.
- **Built to be an evaluation *and* training environment.** The same harness that serves a
  task can measure how good a model is at research, and (privately, on our side) train one.

## What the agent actually does

Each step, the agent picks one move from a small, fixed tool menu — the
[`research-env-v1`](./contract/research-env-v1/) action space:

| Verb | Tools |
|---|---|
| Gather | `web_search`, `fetch_url`, `read_file`, `list_files` |
| Write | `write_file` |
| Run | `run_command` (sandboxed) |
| Experiment | `submit_job`, `get_job` — provision a GPU run, read its results |
| Finish | `finish` |

That's enough to do the real thing: read a paper, implement an idea, launch a training run,
read the metrics, decide what to try next. GPU experiments are **provider-invariant** — the
agent asks for `8xH100`, and the runtime decides *where* to provision it (you never see, and
never have to care, which cloud answered).

## Quickstart

> Bring your own key (BYOK). The installer needs a **Linux x86_64 host with glibc ≥ 2.36**
> (Debian bookworm, Ubuntu 22.04+) and `python3` — the runtime is a Linux binary. Native
> `cargo install` is planned ([#1953](https://github.com/Rockielab/rockie-nugget/issues/1953)).

```bash
# install (assembles the runtime + tool surface from this checkout — config only)
git clone https://github.com/Rockielab/rockie-nugget.git
cd rockie-nugget
./install.sh

# add ~/.local/bin to PATH if it isn't already
export PATH="$HOME/.local/bin:$PATH"

# point it at any OpenAI-compatible model (a frontier model, an open-weight
# model, or your own server) — bring your own key
export OPENAI_BASE_URL=https://api.your-provider.com   OPENAI_API_KEY=sk-...

# run a research task
nugget run "Reproduce the rank-enrichment result from the learned-representations repo
            and propose one experiment that would push effective rank higher."
```

`install.sh` fetches the sha-verified Goose runtime to `~/.local/bin/goose`, registers this
repo's [`research-env-v1` MCP server](./mcp/research-env-mcp/) as the agent's tool surface in
`~/.config/goose/config.yaml`, installs the **Rockie overlay** (below), and installs a
`nugget` launcher that maps your BYOK env to a Goose provider (`OPENAI_*` → openai,
`ANTHROPIC_API_KEY` → anthropic). Re-running is idempotent. Run it headless for long-horizon
work.

The current binary pin is the Rockie release
`nugget-goose-v1.43.0-glibc236`, asset `goose`, SHA-256
`05145ebae89b95aac7d440477fffbdfa999124c60626e5f6209ae24aedc897ba`.
That raw executable is extracted only by the merge-to-main release workflow from the
official `aaif-goose/goose` v1.43.0 Linux x86_64 archive, whose SHA-256 is
`a9a96f559a8b5f20b11597b78e4aa5bb0b9b29796ec4f808ca466a3f59a5ec20`.

## The Rockie overlay

Bare Goose is a capable agent; the **overlay** ([`overlay/`](./overlay/)) is what makes it
reason like *Rockie*. It is config-only — the same files the local installer copies into
`~/.config/goose/` are the files the platform mounts, so **local install ≡ platform runtime**.

- **`overlay/goosehints`** — the ethos. The hard rules, the
  **Plan → Research → Build → Audit → Run → Assess → Codify** loop, the pre-experiment
  checklist, and the Brainstorm → Research → Attack → Validate waterfall. Loaded every turn.
  The installer merges it into `~/.config/goose/.goosehints` under a managed sentinel block,
  so your own hints are never clobbered.
- **`overlay/recipes/`** — composable task templates: `autoresearch.yaml` (frozen-metric
  loop, plus a `campaign_mode=sustained` layer for multi-day operation — concurrent
  run/plan/write-up staffing, a verdict protocol, and a novelty re-verification gate),
  `experiment.yaml` (pre-experiment gate → `submit_job` → poll → report),
  `clean.yaml` (anti-slop pre-commit pass), and `find-skills.yaml` (mine the ~300-skill
  Rockie catalog for the task in front of you). Run one with `goose run --recipe <file>`.
- **`overlay/memory/` + the builtin memory extension** — durable cross-session memory.
  The agent emits `[LEARN]` / `[DEAD-END]` blocks; a `Stop` hook
  ([`overlay/hooks/capture.sh`](./overlay/hooks/)) appends them to plain-text memory the next
  session recalls. No database — plain files, deliberately.
- **`overlay/hooks/session-start.sh`** — a `SessionStart` hook that re-surfaces the
  installed-skills inventory (anything pulled into `./skills/` via `find-skills.yaml`) at the
  top of every session, so a skill you pulled earlier doesn't silently stop getting read once
  that turn ages out of context. Fires at genuine session start; Goose does not yet expose a
  compaction-lifecycle hook the way Claude Code/Codex do, so it can't re-fire mid-session after
  an in-session compaction ([tracked in #24](https://github.com/Rockielab/rockie-nugget/issues/24)).
- **`overlay/ATTRIBUTION.yaml`** — the public attribution manifest for this
  config-only overlay and the upstream community skill credits it references.
  Nugget does not ship direct `SKILL.md` mirrors, so this manifest is the
  portable credit surface.

The overlay names no model identity or provider SKU: it is fully model-agnostic, so it works
identically whether you run BYOK locally or against the served model on the platform.

## Evaluating a model's research ability

rockie-nugget ships an **eval environment** so you can measure how well *any* model does
research *inside the harness* — not on a leaderboard in the abstract, but on the actual loop
it would run. The adapter pattern is a 3-file contract (`prepare` / `run` / `grade`); see
[`eval/adapters/super/`](./eval/adapters/super/) for a worked example against the open
[SUPER](https://github.com/allenai/super) benchmark. Adapters target the open research-agent
benchmarks:

- **RE-Bench** (METR) — real ML R&D engineering (kernels, scaling laws)
- **ScienceAgentBench** — data-driven scientific tasks from real papers
- **SUPER** (allenai) — setting up and running research repos from the wild *(adapter shipped)*
- **MLE-bench** — Kaggle-style ML engineering

```bash
# run the SUPER adapter against a BYOK model (3-file prepare/run/grade contract)
eval/adapters/super/prepare.sh && eval/adapters/super/run.sh   # one model, one harness, one number
```

> A single `nugget eval <bench>` front-end over these adapters is on the roadmap; today
> the adapters run directly.

A note we take seriously: **the harness moves benchmark scores by double digits on its
own**, so rockie-nugget's eval always changes one variable at a time — fix the harness to
compare models, fix the model to compare harness changes. Scores from a moving harness are
noise.

## How it fits with Rockie

rockie-nugget is open and runs anywhere. The [Rockie](https://rockielab.com) platform adds
the parts that need a backend:

- **Skills** — the markdown research toolchain (open).
- **`mcp-rockie`** — the MCP server for dispatching agents to a 24/7 runtime and
  **provisioning GPUs** through Rockie.
- **The Rockie Model** — a Rockie-hosted model we're tuning for long-horizon research. Use
  it from rockie-nugget by pointing at our endpoint; usage meters from your Rockie credits.

You can run rockie-nugget entirely locally with your own model and never touch the platform —
that's the point. Rockie earns its keep when you provision compute or use the hosted model
through it, not by locking up the harness.

## Architecture

```
your task
   │
   ▼
┌─────────────────────────────────────────────┐
│  rockie-nugget loop  (thin, model-agnostic)  │
│  prompt → model → tool-call → result → …     │
└───────────────┬─────────────────────────────┘
                │  frozen, versioned tool contract (MCP)
                ▼
   web · files · run_command · submit_job/get_job · finish
                │
                ▼   (GPU work is provider-invariant — cloud hidden from the agent)
        Rockie GPU provisioning  /  your own compute
```

The agent only ever sees a uniform tool surface. Everything that varies for non-research
reasons — which GPU cloud, connection details, credentials — is pushed *below* the tool
boundary, so a trajectory looks identical no matter where it ran. (That same property is
what lets the environment double as clean training data on our side.)

## Repository layout

| Path | What's there |
|---|---|
| [`overlay/`](./overlay/) | The Rockie overlay (config-only): the ethos `goosehints`, research `recipes/`, the memory scaffold + capture `hooks/`. This is what turns bare Goose into a Rockie harness. |
| [`contract/`](./contract/) | The versioned tool contract (`research-env-v1`) — JSON Schemas, manifest, and the versioning discipline. This is the agent's action space. |
| [`mcp/research-env-mcp/`](./mcp/research-env-mcp/) | A small stdlib-Python stdio MCP server that exposes the contract's tools to any MCP-native agent (e.g. Goose). |
| [`eval/adapters/`](./eval/adapters/) | Benchmark adapters — the 3-file `prepare`/`run`/`grade` pattern for scoring a model *in-harness*. |

## Collaborating

rockie-nugget is being built in the open, and the most interesting open problems in it are
research problems, not engineering ones: reward design for long-horizon research,
contamination-resistant evaluation, and what an agent's tool surface should even *be*. If
you're a researcher working on self-improving AI, agentic research, or agent evaluation —
**we'd love to build this with you, and we mean in person.** Open an issue, pick up a
[good first issue](./CONTRIBUTING.md#good-first-issues), or reach the team at
[rockielab.com](https://rockielab.com).

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for how to get started and
[`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md) for community expectations.

## License

[Apache License 2.0](./LICENSE). rockie-nugget builds on
[Goose](https://github.com/block/goose) (© Block, Inc., Apache-2.0); see
[`NOTICE`](./NOTICE) for attribution.

---

*rockie-nugget is part of the Rockie / Pebble ML stack. 🪨 Another rock on the pile.*
