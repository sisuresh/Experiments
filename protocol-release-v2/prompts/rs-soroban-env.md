---
path: $REPO_ROOT/rs-soroban-env
base: main
group: spine
plan_model: opus
impl_model: opus
plan_effort: high
impl_effort: high
---
The Soroban host — where real semantic implementation happens. Hardest repo in
the chain; both halves run on the frontier model.

- **No protocol feature gates in host code.** Host versions offer no backwards
  compatibility, so additive protocol changes land unconditionally — do not add
  `#[cfg(feature = "cap_...")]` to host logic, and do not add per-CAP cargo
  features. (Precedent: CAP-85 landed ungated; CAP-84's gates were removed.)
  Gate per-function *availability* at runtime via `min_supported_protocol` /
  `check_protocol_version_lower_bound` instead.
- **Check the current `stellar-xdr` dep before changing it.** Once the CAP's XDR
  is merged and released, the workspace dep is a plain
  `version = "=<N>.0.0"` with no git rev — do not reintroduce a git/rev pin or a
  feature list. Only pin to a rev if the CAP's XDR is genuinely unreleased.
- New host functions are declared in `soroban-env-common/env.json` (which
  regenerates the `Env` trait); bodies go in `soroban-env-host`. Adding a host
  function is a significant change — prefer reusing existing host objects and
  accessors, and flag it rather than doing it silently.
- Find an existing exemplar of the same shape and mirror it, including scope
  limits (e.g. CAP-67 muxed *accounts* is the exemplar for muxed *contracts*).
- **Variant CAP → parallel tests + a shared helper.** When the CAP adds a
  variant of an existing type, `grep` the existing variant's tests and add a
  twin for EACH — happy path *and* negative/rejection cases. Don't stop at one
  and don't copy-paste: factor the shared body into a helper parametrized by the
  differing input.
- **Every new host test needs its `observations/<name>.json` recorded and
  committed** — tests check cpu/mem observations against committed files, so a
  test without one is incomplete and diverges in CI. Record with
  `UPDATE_OBSERVATIONS=1 cargo test -p soroban-env-host --features testutils <test>`
  and review the diff before committing.
- Verify BOTH configs: `cargo test -p soroban-env-host --features testutils` and
  `--features testutils,next`. Then `cargo fmt --all`.
- When this merges, everything embedding the host (core's per-protocol
  submodule, rpc's preflight) must re-pin to the merge SHA.
