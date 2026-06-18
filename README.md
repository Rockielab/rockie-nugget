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
  them, fork them, write your own. No DSL, no lock-in.
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

> Intended interface — early; expect rough edges.

```bash
# install
curl -fsSL https://rockielab.com/install.sh | sh    # or: cargo install rockie-nugget

# point it at any OpenAI-compatible model
export OPENAI_BASE_URL=https://api.your-provider.com   OPENAI_API_KEY=sk-...

# run a research task
rockie-nugget run "Reproduce the rank-enrichment result from the learned-representations repo
                   and propose one experiment that would push effective rank higher."
```

Run it headless for long-horizon work, or wire in the Rockie skills + tools to give the
agent dispatch, GPU provisioning, and the full research toolchain.

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
rockie-nugget eval super --model <any-openai-compatible-model>   # one model, one harness, one number
```

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
