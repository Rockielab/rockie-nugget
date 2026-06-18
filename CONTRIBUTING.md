# Contributing to rockie-nugget

Thanks for looking. rockie-nugget is early and built in the open, which means the highest-
leverage contributions right now are *research-shaped*, not just bug fixes. If you work on
self-improving AI, agentic research, or research-agent evaluation, you're exactly who we want
in here.

## The shape of the project

rockie-nugget is a thin, model-agnostic agent loop wrapped around a **versioned MCP tool
contract** (`research-env-v1`) that doubles as a research *evaluation* environment. Three
surfaces are open and where contributions land:

- **`contract/`** — the agent's action space, as versioned JSON Schemas. Changing the tool
  surface is the highest-stakes change in the repo (it's what the model sees), so it follows
  a strict discipline: you don't edit a version in place, you cut a new one. Read
  [`contract/VERSIONING.md`](./contract/VERSIONING.md) before touching it.
- **`mcp/research-env-mcp/`** — the stdio MCP server that exposes the contract to an agent.
- **`eval/adapters/`** — benchmark adapters. Each is a 3-file `prepare`/`run`/`grade`
  contract. Adding an adapter for a new open benchmark is one of the most useful things you
  can do, and a great first contribution.

## How to contribute

1. **Open an issue first** for anything non-trivial — especially tool-contract changes. A
   quick design conversation saves a rewrite.
2. **Keep changes small and focused.** One concept per pull request.
3. **For eval adapters**, follow the existing pattern in
   [`eval/adapters/super/`](./eval/adapters/super/): vendor the benchmark's *own* grader
   (no LLM-judge), keep the harness as the fixed scaffold, and document what task the agent
   actually drove.
4. **Honest results only.** rockie-nugget exists to measure research ability faithfully. A
   score from a moving harness, a leaked answer, or a hand-tuned prompt is worse than no
   number. Change one variable at a time.
5. **Open a pull request** against `main` with a clear description of *what* and *why*.

## Good first issues

These are scoped to get you oriented without needing the whole picture:

- **Add a benchmark adapter** for an open research-agent benchmark (RE-Bench, ScienceAgent-
  Bench, MLE-bench) following the `eval/adapters/super/` 3-file pattern.
- **Improve the MCP server's error grammar** — make `mcp/research-env-mcp/server.py`'s error
  envelopes consistent across all nine tools so the model learns one error shape.
- **Document a tool** — flesh out a per-tool README/example for one of the nine tools in
  `contract/research-env-v1/`.
- **A `v2-example` walkthrough** — turn `contract/v2-example/` into a tutorial for how to cut
  a new contract version without breaking v1 consumers.

Comment on (or open) an issue to claim one. We label these `good first issue` on the tracker.

## Code of Conduct

By participating you agree to the [Code of Conduct](./CODE_OF_CONDUCT.md).

## License

Contributions are accepted under the [Apache License 2.0](./LICENSE), the same license the
project ships under.
