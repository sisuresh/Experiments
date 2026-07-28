---
path: ~/dev/stellar-rpc
base: protocol-next
group: leaf
plan_model: opus
impl_model: sonnet
---
Stellar RPC. Base branch is `protocol-next`, NOT main.

- Repin the Rust/Go deps to this run's pushed heads.
- `dependency-sanity-checker` and the `complete` rollup fail by design during a
  protocol transition — treat as non-blocking.
