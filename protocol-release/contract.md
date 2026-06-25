# Driving a Stellar Protocol-Release PR Stack with an LLM

## Context

When a new Stellar protocol version ships, the same kind of "bump XDR / pull
in new soroban-env / regen / retitle" work has to land across roughly a
dozen repos in a specific order. The mechanical parts are repetitive enough
that an LLM can drive them — what it needs is a single doc that lists
**which repos**, **in what order**, **what file to touch**, and **how to
verify the bump landed**. This is that doc. The LLM should discover the
specific commits, version numbers, and CI quirks of a given release on its
own; this document is just the shape of the work.

---

## Inputs the LLM needs

The driving prompt should supply:

- The new protocol number.
- The CAP's XDR changes (from the CAP's "XDR Changes" section). If they
  aren't in `stellar-xdr` yet, the flow authors them on `main` gated behind a
  feature `#ifdef` (see `lessons.md`); if already in, just the canonical
  commit it pins.
- Any per-CAP feature flags the release expects to enable / drop (these
  determine the `XDR_FEATURES` lists in downstream regens, and must match the
  flag name used in the `.x` `#ifdef`).

That's it. The SPIKE PRs the LLM opens for `rs-stellar-xdr`,
`rs-soroban-env`, and `stellar-core` will themselves produce the
commits that further-downstream SPIKE PRs reference. Everything else
(current pin values, downstream `replace` directives, CI config) the
LLM reads from each repo's source as it walks the chain.

---

## Dependency chain

```
stellar-xdr                          (canonical .x)
   │
   ├──▶ rs-stellar-xdr               (Rust XDR codec; regens from stellar-xdr)
   │       │
   │       └──▶ rs-soroban-env       (Soroban host)
   │               │
   │               └──▶ rs-soroban-sdk
   │
   ├──▶ stellar-core                 (validator; submodule + Cargo deps.
   │       │                          Protocol-version + overlay-version
   │       │                          bumps live here.)
   │       │
   │       └──▶ docker-stellar-core-horizon (Quickstart)
   │
   ├──▶ go-stellar-sdk               (Go SDK; regens its own XDR from
   │       │                          stellar-xdr)
   │       │
   │       ├──▶ stellar-horizon
   │       │
   │       └──▶ stellar-rpc          (Go + Rust; also pins rs-soroban-env
   │                                  and rs-stellar-xdr on the Rust side)
   │
   ├──▶ js-stellar-base              (JS XDR + tx builder; regens from
   │       │                          stellar-xdr)
   │       │
   │       └──▶ js-stellar-sdk
   │               │
   │               └──▶ stellar-laboratory
   │
   ├──▶ js-stellar-xdr-json          (WASM XDR↔JSON via rs-stellar-xdr)
   │       │
   │       └──▶ stellar-laboratory
   │
   └──▶ stellar-cli (contract)       (pins rs-stellar-xdr + rs-soroban-sdk)

Lazy consumers picked up later: stellar-quorum-analyzer,
stellar-prometheus-exporter, supercluster.
```

**Land order:**

1. `stellar-xdr` — if the CAP's types aren't in yet, author them on `main`
   gated behind a feature `#ifdef` (see `lessons.md`); otherwise confirm the
   pinned commit. `curr`/`next` regenerate automatically.
2. `rs-stellar-xdr` — XDR regen, version bump
3. `rs-soroban-env` — host code + xdr dep bump, version bump
4. `stellar-core` — submodule + Cargo bumps, protocol + overlay version
5. Parallel branch A (Go): `go-stellar-sdk` → `stellar-horizon` → `stellar-rpc` (Go side)
6. Parallel branch B (Rust): `rs-soroban-sdk` → `stellar-cli` → `stellar-rpc` (Rust side)
7. Parallel branch C (JS): `js-stellar-base` → `js-stellar-sdk` → `stellar-laboratory` + `js-stellar-xdr-json`
8. `docker-stellar-core-horizon` — bump every dep ref in `images.json`
9. Lazy consumers

**The SPIKE pass covers the entire chain (steps 2–8).** Each SPIKE PR
points at the unmerged ref of its direct upstream — `rs-soroban-env`
SPIKE references the `rs-stellar-xdr` SPIKE branch, `stellar-core` SPIKE
references both, `go-stellar-sdk` SPIKE references `stellar-xdr` directly
via Makefile commit, and so on. As each upstream SPIKE merges, the LLM
re-pins its downstreams to the tagged release. Until then, every
downstream pin uses whatever the unreleased SPIKE-branch ref-resolution
mechanism is for that ecosystem:

- Cargo: `git = "..."`, `rev = "..."` workspace deps
- Go: `replace` directives in `go.mod` pointing at fork pseudo-versions
- npm/yarn: local-file tarballs (`file:...`) or git-URL deps
- stellar-core: submodule pointer + `Cargo.lock` `[patch]` sections

The LLM should be able to open all of 2–8 in parallel within ~one
working session, then productionize as upstreams merge.

---

## Per-repo PR mechanics

For each repo, the same loop applies:

1. **Find the pin file(s)** — typically one of:
   - `Cargo.toml` workspace deps (Rust)
   - `go.mod` direct deps or `replace` directives (Go)
   - `package.json` dependencies (JS/TS)
   - `Makefile` regen variables (Go/JS repos that regen XDR from source)
   - `.gitmodules` + a commit-hash file (stellar-core's xdr submodule)
   - `images.json` (Quickstart)
2. **Bump the pin** to the upstream release ref.
3. **Regen, then build AND run the relevant tests locally before pushing** —
   per the repo's README/Makefile. Best effort: if the local toolchain can't
   build (missing deps, no DB, etc.), fall back to push + rely on CI, and note
   it in the PR.
4. **Fix any fallout** the build/tests surface (deprecated APIs, generated-code
   changes, test fixtures that no longer decode, mock interfaces that need
   new methods).
5. **Push, watch CI, iterate.**

The LLM should infer which of these apply for a given repo by reading the
repo's top-level files. Don't memorize specifics — they drift between
releases.

---

## The PR loop: two models + CI

Each repo's PR goes through a **plan-review-execute-watch** cycle driven by
two different models — `claude` plans/executes, `copilot --model gpt-*`
reviews. Two plan-review rounds before the PR opens; then CI is the only
remaining gate, and any CI failure starts another plan-review-fix round.

The pattern is borrowed from `stellar-experimental/henyey`'s
`scripts/plan-do-review-loop.sh` — we use only the "two-model exchange
per unit of work" idea, not its issue-board scheduler.

```
For each repo in land order:
  PLAN-REVIEW × 2:
    1. claude:           draft a plan (file edits, regen steps, PR title)
    2. copilot/gpt:      review; LGTM or list concerns
    3. claude:           revise based on review (skipped if LGTM on first pass)
    4. copilot/gpt:      final review
  EXECUTE:
    5. claude:           apply edits, commit, push, open draft PR
  CI LOOP:
    6. wait for CI
       CI green → done with this repo. Move on.
       CI red   → fetch failed-job logs → repeat PLAN-REVIEW × 2 → push
                  fix → GOTO 6.
  Escalate to user only after 2–3 unsuccessful CI iterations on the same
  failure signature.
```

This whole cycle lives in a small driver script (next section); the
doc you're reading is what the script feeds the models as their shared
contract.

CI commands the script uses:

```bash
gh pr checks <num> -R <org>/<repo> --watch          # block until done
gh pr view   <num> -R <org>/<repo> --json statusCheckRollup
gh run view  -R <org>/<repo> --job <job-id> --log   # for failed jobs
gh run view  <run-id> -R <org>/<repo> --log-failed
```

Reading CI fail logs (heuristics for the planner):

- Look for `FAIL\b`, `--- FAIL`, `panic:`, `error:` first.
- If the only failure signal is `Process completed with exit code 143`
  (SIGTERM, no stack), it's a timeout — walk back to find the last test
  that didn't print `ok`; that's the slow/hung one.

When a CI failure is a real product break — not a flake, not a test
expectation that needs updating for the new protocol — stop landing the
chain and escalate.

### Feature-implementation repos (stellar-core, rs-soroban-env)

When the inputs file asks this run to *implement* a CAP (not just propagate
it), stellar-core / rs-soroban-env are in-scope. There is no reference PR —
use the most recent protocol-version-bump commits in the local checkout as
the exemplar, plus that repo's `lessons.md` section.

- **Build + test these locally before pushing.** rs-soroban-env: `cargo
  build`/`cargo test`. stellar-core: `./configure
  --enable-next-protocol-version-unsafe-for-production`, build, run the
  affected tests. If the CAP is observable in LedgerCloseMeta, capture it from
  a core test (`--capture-lcm`) and commit the `.xdr` into horizon's
  LCM-ingestion fixtures (see `lessons.md` stellar-horizon).
- **stellar-core TxMeta check:** a red `--check-test-tx-meta` is fine to fix
  by re-recording the baseline and committing — expected when the CAP changes
  tx semantics or adds tests. Inspect the JSON diff; if a tx changes that you
  did not expect, flag it in the PR for the reviewer, but still commit and
  continue. Human review catches it downstream.
- **stellar-core deb/image artifacts lag the PR — monitor and wait by commit.**
  The Jenkins build is triggered manually, but its outputs are detected
  automatically. Any step depending on a core deb/image (e.g. the horizon/rpc
  integration matrix legs) must wait for the artifact whose embedded commit
  matches the core PR HEAD: each watch pass re-checks the apt pool and
  `unsafe-stellar-core` docker repo (commands + naming in `lessons.md`). A
  downstream red caused by the artifact not existing yet is `SKIP`, not a fix.
  Only once the matching artifact appears, pin the downstream deb/image to it
  and proceed.

---

## Driver script: `protocol-release-loop.sh`

Single-invocation bash driver. Lives at
`~/.claude/scripts/protocol-release-loop.sh`. Processes every in-scope
repo in one run; downstream CI failures can route fixes to upstream PRs.

### Inputs

```
protocol-release-loop.sh <inputs-file>
```

The inputs file is plain markdown. The script reads only one structured
block — a `## Repos` section listing repo paths in dep order, one per
bullet. Everything else in the file is free prose for the planner and
reviewer to consume.

Example:

```markdown
# Protocol 28 — CAP-0083 only

Protocol number: 28
stellar-xdr commit: <sha>
Feature flags enable: CAP_0083
Feature flags drop:   (none)

## Repos
- /Users/.../stellar-horizon
- /Users/.../stellar-rpc

## Notes
- Base branch for both: protocol-next
- DO NOT bump rs-soroban-env; current pin is correct for CAP-0083.
- stellar-core already implements CAP-0083 — no PR needed there.
```

### Dependencies

- `claude` (Claude Code CLI) with `-p` non-interactive mode.
- `copilot` (GitHub Copilot CLI) with `--model` for selecting a GPT.
- `gh` CLI authenticated for the target repos.
- `jq` for state + CI JSON parsing.

### Phase 1: Open

For each repo in the inputs `## Repos` list, in order:

1. Skip if state file already records an open PR for this repo.
2. `plan_then_review` ("bump this repo for the protocol release per the
   contract") — claude plans, copilot/gpt reviews up to 2 rounds.
3. claude executes the plan: edits, commit, push, `gh pr create --draft`.
4. Capture PR URL; persist to state file.

### Phase 2: Watch

Outer loop, capped at `MAX_WATCH_ITERS` (default 12), `WATCH_INTERVAL`
seconds (default 60) between passes. Each pass:

For each open PR (in dep order):

- Green → log, skip.
- Pending → log, skip.
- Red →
  - Pull failure-signal lines from the first failing job.
  - `plan_then_review` ("CI red on $pr; fix may belong here OR in an
    upstream PR") with the **full open-PRs context block** — every
    repo's PR URL and CI status — included in both the plan and review
    prompts.
  - The planner can either:
    - Output `SKIP` (waiting on an upstream that isn't green yet — the
      script does nothing for this PR this pass).
    - Produce a fix plan naming a target repo + branch (this PR's
      repo, OR any upstream PR's repo).
  - claude executes the fix: `cd`s to the named repo and pushes to
    its existing PR branch — no new PR is opened.
- Same failure signature appearing twice in a row on the same PR →
  mark that repo `ESCALATED` in state; planner won't be invoked on it
  again this run.

Pass ends when every PR is either green, escalated, or no actionable
work was found (all reds were SKIP or already-escalated). Loop continues
until `all_done` (every repo green or escalated) or `MAX_WATCH_ITERS`.

### State + resume

State file: `~/.local/state/protocol-release-loop/<inputs-hash>.json`,
a flat JSON object mapping repo path → PR URL (or the string
`"ESCALATED"`).

Re-running the script with the same inputs file resumes from state:
opens skip already-recorded PRs, watch picks up where it left off. To
start fresh, delete the state file.

### How the doc and script relate

- The **doc** (this file) is the *contract* — the dep chain, the per-repo
  pin-file conventions, the gotchas. It's read-only context for both
  models on every prompt.
- The **script** is the *engine* — orchestrates plan-review rounds, the
  open phase, and the cross-PR watch phase. Knows nothing protocol-
  specific.
- The **inputs file** is the per-release *delta* — protocol number,
  stellar-xdr commit, feature flag changes, in-scope repo list, and
  free-form notes ("don't bump rs-soroban-env this round", "target
  protocol-next", etc).
- New protocols change inputs only.

### Source

The actual implementation lives at
`~/.claude/scripts/protocol-release-loop.sh`. It's a single bash file
(~390 lines) — read it for ground truth. Key functions:

- `plan_then_review` — two-round plan/review exchange (claude + copilot/gpt).
- `open_prs_context` — formats the cross-PR status block fed into every
  plan-review prompt.
- `failure_signal` — pulls the first failing job's grep-filtered log
  excerpt for use in the fix plan prompt.
- `pr_is_green` / `pr_is_pending` — CI status predicates.
- `state_get` / `state_set` — JSON state file for resume.

---

## Cross-cutting conventions

### Branch + PR naming

- **SPIKE PRs** (against unreleased upstream): branch named after the
  release/feature, PR title prefixed `SPIKE:`, opened as **draft**.
- **Real PRs** (against tagged upstream releases): plain title naming the
  protocol/feature; no `SPIKE:` prefix; not a draft.
- Keep the branch name stable across the dep stack — easier
  cross-linking. Don't rename branches when scope changes (CAPs added or
  dropped from a release); update titles instead.

### Cross-linking

Each downstream PR's description should reference its direct upstream(s).
Reviewers (and future LLM runs) navigate the chain that way.

### When CAPs get dropped from a release

If a CAP is removed mid-flight:

1. The XDR regen with that CAP's feature gate off will strip its types
   from generated code. All downstream regens flow from that.
2. Any test fixture encoding values of the now-removed types becomes
   un-decodable — delete those fixtures.
3. PR titles/descriptions get updated; branches keep their original names.

---

## Token / auth gotchas

- The `gh` CLI token defaults to `repo` scope. **Pushing a commit that
  touches `.github/workflows/*.yml` requires the `workflow` scope.** If a
  workflow tweak ships together with code, either:
  - `gh auth refresh -s workflow`, or
  - split the workflow change into a separate commit pushed via SSH (or
    another auth path), keeping code-only commits pushable via the gh
    token.
- HTTPS pushes to a personal fork can fail if git is using shared-org
  credentials. `gh auth setup-git` inserts the gh token into the credential
  helper, which fixes it.

---

## Files this document doesn't cover

- The protocol design itself (CAPs, threat model, host behavior). Those
  live in `stellar/stellar-protocol`.
- E2E test harnesses for CAP-specific behavior. Those need bespoke setups
  and aren't a gate for landing the PR stack.
- Performance baselines (apply-load missions, supercluster runs).
  Coordinate with the perf team after the stack is on the new protocol.
