# protocol-release

Drives a Stellar protocol-release PR stack end-to-end across the whole
repo dependency chain (stellar-xdr → rs-stellar-xdr → rs-soroban-env →
… → quickstart). Claude plans and executes; a second model (copilot)
reviews plans. One invocation opens, refreshes, and babysits every PR
for a release.

## Usage

```sh
./loop.sh <inputs-file>          # e.g. ./loop.sh p28-cap-0084.md
DRY_WATCH=1 ./loop.sh <inputs>   # read-only status snapshot, no LLM calls
```

## Phases

1. **OPEN** — walk `## Targets` in dep order; plan → review → open one
   draft PR per repo. Repos with a recorded PR are skipped (re-runs are
   idempotent).
2. **REFRESH** (1.5) — for already-open PRs, top-down: if the branch is
   DIRTY/BEHIND vs its base, or an upstream PR branch was pushed earlier
   in the same pass, merge the base into the existing branch (append-only
   — never rebase/force-push), repin to refreshed upstream heads, build,
   push. `REFRESH=0` skips.
3. **WATCH** — poll every PR (CI status + merge state); dispatch parallel
   fix jobs for actionable reds; exit when all green/merged, or STALLED
   with an operator TODO list.

## Files

- `loop.sh` — the driver. Header comment documents all env knobs
  (`CLAUDE_MODEL`, `DEFAULT_EFFORT`/`MAX_EFFORT`, `MAX_PARALLEL_FIXES`,
  `WATCH_INTERVAL`, `IGNORED_CHECKS`, …).
- `contract.md` — standing rules every planner/executor reads (PR
  conventions, base branches, build handoff protocol).
- `lessons.md` — accumulated per-repo traps from previous releases.
  Append to it whenever a run trips on something new.
- `p28-*.md` — per-release inputs: protocol number, CAP scope, targets
  in dep order, and freeform notes. Copy one as a template.

## State & logs

- State (PR URLs per repo, keyed by inputs-file path):
  `~/.local/state/protocol-release-loop/<id>.json`
- Live status table (rewritten every poll pass — `watch cat` it):
  `~/.local/state/protocol-release-loop/<id>-status.txt`
- Runlogs + per-call LLM replies + token/cost TSV:
  `~/.local/share/protocol-release-loop/logs/`

Exit codes: `0` all green/merged · `2` escalations or iterations
exhausted · `3` stalled on operator action (merge PRs, publish
artifacts, then re-run).
