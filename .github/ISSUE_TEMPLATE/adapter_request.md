---
name: Benchmark adapter
about: Propose or claim a benchmark adapter (the 3-file prepare/run/grade pattern)
title: "[adapter] "
labels: good first issue, adapter
---

**Benchmark**
Which open research-agent benchmark? (RE-Bench, ScienceAgentBench, MLE-bench, …)
Link + license:

**License & data access**
- License (must be open):
- Is the task data publicly downloadable (no gated agreement)?

**Grader**
Does the benchmark ship its own deterministic grader we can vendor verbatim? (We do **not**
use LLM-judges.) Link to the grader:

**Smallest credible task**
Which single task is the lowest-friction one to wire up first?

**Are you claiming this?**
- [ ] I'd like to build this adapter following `eval/adapters/super/`.
