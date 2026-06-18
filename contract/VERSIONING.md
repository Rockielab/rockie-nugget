# Versioning the action space

Each version is a self-contained directory (`research-env-v1/`, `research-env-v2/`, …)
holding a `manifest.json` plus one JSON Schema per tool under `tools/`. The top-level
`VERSION` file names the **current** version. To cut a new version: copy the current
directory to the next number, make the change (add / modify / remove a tool schema, update
`manifest.json`), bump `VERSION`. The old version is left untouched — never edit a published
version in place. A diff between two version directories is exactly the action-space change,
which is what later RL work (and any audit) needs. **The single invariant:** within one
eval or experiment run, one version is read end-to-end (selected once at run start from
`VERSION` or an explicit pin); versions change *across* runs as the harness improves
(spec A6), never *mid*-run. This is a versioning discipline, not a freeze — iterating the
menu is the expected, cheap path; the byte-identical lock is a future RL-phase trigger.
