---
path: ~/dev/rs-soroban-env
base: main
group: spine
plan_model: opus
impl_model: opus
plan_effort: xhigh
impl_effort: high
---
The Soroban host — where real semantic implementation happens. Hardest repo in
the chain; both planning and implementation run on the frontier model.

- Repin the workspace `stellar-xdr` dep to the rs-stellar-xdr head from this
  run and enable that CAP's feature on the dep. Refresh `Cargo.lock`.
- **No protocol feature gates in host code.** Host versions offer no backwards
  compatibility, so additive protocol changes go in unconditionally — do not
  add `#[cfg(feature = "cap_...")]` to host logic. (Precedent: CAP-85 landed
  ungated.) The XDR dep's feature is the only place a cap flag appears.
- Look for an existing exemplar of the same shape before designing new code
  (e.g. CAP-67 muxed *accounts* is the exemplar for muxed *contracts*) and
  mirror it, including scope limits.
- Prefer reusing existing host objects/accessors over adding host functions.
  Adding a host function is a big deal — flag it rather than doing it silently.
- Tests use a golden-observation framework. A test that has never run in a
  given config has no recorded observation and will fail; record with
  `UPDATE_OBSERVATIONS=1 cargo test ...` and review the diff.
- Verify BOTH configs: `cargo test -p soroban-env-host --features testutils`
  and `--features testutils,next`. Then `cargo fmt --all`.
