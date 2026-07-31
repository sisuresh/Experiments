---
path: ~/dev/rs-stellar-xdr
base: main
group: spine
plan_model: opus
impl_model: sonnet
---
Rust XDR bindings. No `curr` module — everything is at the crate root, gated by
`cap_*` features.

- **Regen:** the `.x` source is the `xdr/` **git submodule** (not a Cargo pin).
  Bump it to the new stellar-xdr commit, add the `cap_<n>_<title>` feature in
  `Cargo.toml`, then `make generate` (rewrites `src/generated*`).
- **Run ONLY `make generate`. Do NOT run `make build` / `make test`.** Those run
  `cargo-hack --feature-powerset` — ~80 min serially and pure duplication of
  CI. This repo is the exception to the build-locally rule. For a quick check,
  `cargo build --features <cap_token>,std` is enough.
- **Each added `cap_*` feature DOUBLES the CI powerset, and a third one exceeds
  GitHub's 256-jobs-per-matrix cap** — `build`/`test` then silently never spawn
  (no error, the jobs just don't appear) and the `complete` aggregator goes red.
  Do not read that as a code failure or as "still queued". Diagnose by counting:
  `gh api repos/stellar/rs-stellar-xdr/actions/runs/<id>/jobs --jq .total_count`
  (~6 = matrices never expanded). The fix is sharding the workflow — a
  maintainer decision, so **surface it in the PR, don't patch the workflow
  inside a CAP PR**.
- **A feature must exist for EVERY cap in flight.** If the base already has
  another CAP's feature, your regen must keep it — downstream needs one rev
  carrying all in-flight caps.
- **After an upstream stellar-xdr PR is SQUASH-merged, re-pin to the new `main`
  commit** — the PR branch head is unreachable from `main`. Get it from
  `gh pr view <n> -R stellar/stellar-xdr --json mergeCommit`. If both commits
  share the same tree, the re-pin yields only a submodule-pointer +
  `xdr-version` diff with zero generated churn — expected, not a failed regen.
