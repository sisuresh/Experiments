---
path: ~/dev/rs-stellar-xdr
base: main
group: spine
plan_model: opus
impl_model: sonnet
---
Rust XDR bindings. Mostly regeneration, but the feature wiring matters.

- Bump the `stellar-xdr` submodule/pin to the upstream stellar-xdr head, then
  regenerate — never hand-edit generated `curr`/`next` files.
- Add a per-CAP leaf feature `cap_<nnnn>_<slug>` in Cargo.toml and make the
  umbrella `next` feature aggregate it. The leaf must NOT pull in `next`
  (that creates a cycle).
- A feature must exist for EVERY cap in flight. If the base branch already has
  another CAP's feature (e.g. `cap_0085_*`), your merge/regen must keep it —
  downstream repos need one single rev that has all in-flight caps.
