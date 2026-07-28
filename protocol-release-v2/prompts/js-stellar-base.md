---
path: ~/dev/js-stellar-base
base: master
group: leaf
plan_model: opus
impl_model: sonnet
---
JS base library. Confirm the default branch before branching (master vs main).

- Regenerate JS XDR with the same `XDR_FEATURES` flag token as upstream.
- If the CAP adds an address/type variant, JS often needs hand-written helpers
  alongside the regen (strkey handling, type guards) — check for the previous
  CAP's equivalent and mirror it.
