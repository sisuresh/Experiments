---
path: ~/dev/rs-soroban-sdk
base: main
group: spine
plan_model: opus
impl_model: sonnet
---
Contract SDK. Usually a repin + regen, occasionally new surface area.

- Repin the env/XDR git-rev deps to this run's pushed heads and refresh lockfiles.
- If the host dropped a cargo feature this run, remove references to it here —
  a stale `soroban-env-*/cap_...` feature reference breaks the build.
- `check-git-rev-deps` failing because it points at an unmerged upstream PR is
  EXPECTED while the stack is in flight; note it, don't fight it.
