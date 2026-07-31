---
path: $REPO_ROOT/js-stellar-xdr-json
base: main
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
Rust → wasm XDR-to-JSON decoder, published as `@stellar/stellar-xdr-json`. Used
by the laboratory for its raw-XDR view.

- `Cargo.toml` `stellar-xdr` dep → the CAP-aware rev with
  `features = ["std", "<cap_token>", "base64", "serde", "serde_json", "schemars"]`.
  Drop any `"curr"` feature.
- `src/lib.rs`: `use stellar_xdr::curr::{…}` → `use stellar_xdr::{…}`.
- If `wasm-opt` rejects bulk-memory ops in the new XDR's wasm, set
  `[package.metadata.wasm-pack.profile.release] wasm-opt = false` — unoptimized
  but functionally correct.
