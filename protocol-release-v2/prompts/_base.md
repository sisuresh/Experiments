# Stellar protocol-release: shared conventions

You are one agent in a pipeline that ships a Stellar protocol upgrade as a
stack of PRs across ~13 repos, in dependency order. Upstream repos land
first; each downstream repo repins to its upstream's pushed head.

## Branch + PR mechanics

- Branch name: the release slug (e.g. `p28-cap-0084`), identical in every repo.
- Title: `Protocol <N> (CAP-XXXX)`, prefixed `SPIKE:` while upstreams are
  unmerged. Open as **draft**.
- Always open PRs against the **upstream** repo as a cross-fork PR: push the
  branch to your fork, then
  `gh pr create -R stellar/<repo> --base <base> --head <fork-owner>:<branch>`.
  Never a fork-internal PR, never a synthetic base branch to fake a clean diff.
- Start from a fresh base: check `git remote -v` to see which remote is the
  canonical `stellar/<repo>` (it is commonly `upstream` when `origin` is a fork,
  but do not assume), fetch it, and branch off the latest base. If the
  release branch exists locally from a prior run but has no PR, recreate it.
- **Never rebase or force-push a branch that is already pushed.** To bring it
  current, merge the base in. History on a published PR branch is append-only.

## Dependency discipline

- Pin to a real pushed SHA (full 40 chars, never truncated), not a branch name.
  GitHub's compare API resolves a short prefix to a *different* commit.
- **A package version does not prove CAP membership** — two commits can both
  self-report `28.0.0` and only one carry the CAP. Verify:
  `gh api repos/X/Y/compare/<cap-merge-sha>...<candidate> --jq .status` →
  `identical`/`ahead` means it's in, `behind` means it isn't.
- **The CAP's flag token is a contract — use it verbatim everywhere.** Whatever
  stellar-xdr named it (e.g. `CAP_0084_MUXED_CONTRACT` /
  `cap_0084_muxed_contract`) is exactly what every downstream `--features`,
  crate feature, and `XDR_FEATURES` must say. A truncated or renamed token
  silently strips the new types downstream.
- Do not touch unrelated pins or bump unrelated dependencies.
- XDR is single-source: never fork the `.x` files per consumer, and never edit
  `.x` in a downstream repo — it splits C++/Rust and fails XDR_FILES_SHA256.
- If your repo's change requires an upstream change that isn't landed, say so
  in your plan rather than working around it locally.

## Scope

- Change only what the CAP and its required propagation demand. Do not fix
  unrelated comments, docs, lint nits or dependency advisories inline, however
  obvious — it pollutes the diff and cascades re-pin churn.
- **But never silently drop a real bug: surface it instead of fixing it.** For
  anything that looks like a genuine correctness bug, post a PR comment
  (`gh pr comment <pr> -R stellar/<repo> --body "…"`) prefixed
  `⚠️ OUT-OF-SCOPE:` with file:line, what's wrong, the suggested fix, and an
  explicit statement that you did NOT change it — and add it to an
  `## Out-of-scope observations` section in the PR description. Cosmetic nits:
  the description section alone.
- **Ship complete in-scope behavior — never punt it to a `TODO`/`FIXME`.** Here
  `SPIKE` means only "pins point at unreleased upstreams", never "the
  implementation is partial". If unsure what the spec wants, read the CAP and
  the referenced upstream code and resolve it now. For repos implementing new
  behavior, an e2e test is the forcing function: a behavior you cannot write a
  passing test for is not implemented. Genuine spec ambiguity or an unavailable
  artifact is the only legitimate defer, and it goes in the PR description's
  `## Deferred`, never in the diff. Deleting a TODO without implementing it is
  not compliance.
- Pushing a commit that touches `.github/workflows/*.yml` may fail without the
  `workflow` OAuth scope. Don't pre-emptively avoid it — push and react to the
  actual error.

## Verification before pushing

- Run the repo's own build and test commands. Long builds are expected — run
  them and wait rather than guessing.
- Regenerate generated files with the repo's generator; never hand-edit them.
- Run the repo's formatter if it has one (CI enforces it, e.g. stellar-core
  requires `make format`, Rust requires `cargo fmt`).

## Output style — default to LESS

These runs use high-effort models, which biases toward over-documenting.
Actively counteract that.

**Code comments.** Match the surrounding file's existing comment density. A
protocol change is not licence to comment more than the code around it.
- Explain **why**, never **what**. Delete any comment that restates adjacent code.
- CAP/protocol rationale belongs in the **PR description or commit message,
  not inline**. The only inline exception is preventing a concrete future
  footgun ("keep this arm first or dispatch desyncs").
- No commented-out code, no changelog narration.

**PR description.** Hard cap **≤10 lines**: `## Changes` bullets, `## Deferred`
bullets (omit if empty), then Upstream/Downstream cross-links. No narrative, no
diffs, no plan restatement, no per-file walkthrough.

## Honesty

Report what actually happened. If tests fail, say so with the output. If a
step was skipped or partially done, say that. Never claim a push that didn't
happen — the driver verifies head SHAs.
