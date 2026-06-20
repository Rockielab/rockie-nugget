# Spec — Align run_command README output contract

**Status:** draft
**Origin:** pr-approval-followup
**Priority:** priority-overnight
**Constitution pin:** CLAUDE.md@unknown, docs/decisions.md@unknown
**Estimate:** 1 commit / 10 min
**Linked artifacts:**
  - spec: specs/run-command-readme-output-contract-2026-06-20.md (this file)
  - design: designs/run-command-readme-output-contract-2026-06-20.md (not needed)
  - plan: plans/run-command-readme-output-contract-2026-06-20.md (not needed)
  - PR: #7
  - fleet-task issue: #<filled by file-fleet-task.sh>
  - source PR: #7

## Clarifications resolved

- PR #7 intentionally changed `run_command` from undifferentiated stdout+stderr text to stdout followed by a labeled `[stderr]` block and `[exit <code>]`.
- The canonical schema now states this shape, but `contract/research-env-v1/README.md` still summarizes the old "combined stdout+stderr" contract.
- This is documentation-only follow-up work; the merged implementation and tests are not in scope.

## Why

The contract README is an entrypoint for downstream MCP consumers and harness authors. Leaving it with the old combined-output wording makes the action-space contract look internally inconsistent after PR #7.

## Goals

- Update the `run_command` row in `contract/research-env-v1/README.md` to match the schema and implementation merged in PR #7.
- Keep the wording concise: stdout first, optional labeled stderr block, explicit exit marker, replacement-decoded non-UTF-8 bytes, and explicit truncation markers.

## Non-goals

- Do not change `mcp/research-env-mcp/server.py` behavior.
- Do not broaden output handling for other tools.
- Do not rewrite the full contract README beyond the affected `run_command` wording.

## Requirements (EARS-style acceptance criteria)

- WHEN a reader opens `contract/research-env-v1/README.md` THEN the `run_command` row SHALL describe stdout, labeled stderr, and exit-code output consistently with `contract/research-env-v1/tools/run_command.json`.
- IF the README mentions non-UTF-8 or oversized output THEN it SHALL state that bytes are replacement-decoded or explicitly marked as truncated rather than silently dropped.
- WHILE the documentation is updated THE implementation and tests SHALL remain unchanged unless a typo in the docs requires a direct quote adjustment.

## Files touched (initial guess; cascade Explore can refine)

- contract/research-env-v1/README.md

## Tasks (commit/PR-level checklist)

- [ ] T1: Update README row — acceptance: `run_command` summary no longer says undifferentiated combined stdout+stderr — expected commits: 1
- [ ] T2: Cross-check schema wording — acceptance: README and `tools/run_command.json` do not conflict on output shape — expected commits: 0

## Large-spec routing check

- [x] Estimate and repo surfaces checked before issue filing
- [x] If over threshold: parent epic body + child issue bodies scaffolded
- [x] If under threshold: normal `/write-spec` fleet-task filing is appropriate

## Risks + open questions

- The repo lacks `CLAUDE.md` and `docs/decisions.md`, so the constitution pin is recorded as `unknown`.

## Review & acceptance checklist

- [x] Spec body unambiguous (Implementer wouldn't have to guess)
- [x] Files-touched covers the change
- [x] Acceptance criteria observable + testable (EARS form)
- [x] Non-goals enumerated (scope creep guard)
- [x] Constitution pin matches current CLAUDE.md + docs/decisions.md SHAs
- [x] Clarifications resolved (any open Qs flagged in Risks)
- [x] Estimate set (commits + wallclock)
- [x] Large-spec routing checked (>5 commits OR >2 repo surfaces)
