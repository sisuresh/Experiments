---
path: ~/dev/stellar-core
base: master
group: spine
plan_model: opus
impl_model: opus
plan_effort: xhigh
impl_effort: high
---
C++ validator. Base branch is `master` (not main). Slow build; hard repo.

- Repin the Rust deps in `src/rust/Cargo.toml` to this run's heads; regenerate
  `Cargo.lock`. Keep the version constraint consistent with what the host
  self-reports.
- The p28 max-protocol bump may already be in from earlier CAP work. **Do not
  duplicate it** — gate new behavior behind the existing protocol constant in
  `src/util/ProtocolVersion.h`.
- Watch for merge artifacts the merge tool won't flag as conflicts — e.g. a
  duplicated `mod p28` / `use ...p28` block after merging master. Build to find them.
- Re-recording `test-tx-meta-baseline-*` is expected when the CAP changes tx
  semantics. Inspect the diff; if a tx changed that you did NOT expect, call it
  out in the PR for a human, but still commit and continue.
- CI enforces clang-format: run `make format` before pushing.
- Build with `make -j12`. If sccache errors with "Operation not permitted",
  stop the sccache server or unset RUSTC_WRAPPER and rebuild.
