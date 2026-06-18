# v2-example — proof that bumping the action space is cheap

This directory is a worked example for `../VERSIONING.md`, not a shipped version. It shows
what a `research-env-v1` → `research-env-v2` bump looks like: **add one tool** (`cancel_job`,
which the menu lacked — stop a running GPU experiment, provider-invariant by the same §3.3
boundary).

The entire change is:

1. add one schema file: `tools/cancel_job.json`,
2. add two lines to `manifest.json` (the version string `v1`→`v2`, and one `tools[]` entry),
3. (when promoting for real) bump the top-level `VERSION` file to `research-env-v2`.

Nothing in v1 is edited; the nine v1 tools are byte-identical copies. The diff IS the
action-space change. Verify with:

```sh
diff -rq ../research-env-v1/tools v2-example/tools   # only cancel_job.json differs
diff <(jq -S . ../research-env-v1/manifest.json) <(jq -S . manifest.json)
```

That is the whole point of A2: iteration (A6's job) is a small, clean, auditable change.
