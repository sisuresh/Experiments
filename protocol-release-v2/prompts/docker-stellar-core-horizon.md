---
path: ~/dev/docker-stellar-core-horizon
base: master
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
Quickstart image (repo is stellar/quickstart). Confirm the default branch.

- Match the previous protocol's `-vnext` image/deb variant naming.
- Wait for the core artifact whose commit matches the core PR HEAD — a
  mismatched-commit artifact is the usual cause of a red build here. If it
  hasn't published yet, say so rather than pinning something wrong.
