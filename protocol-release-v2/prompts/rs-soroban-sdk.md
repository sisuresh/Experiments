---
path: ~/dev/rs-soroban-sdk
base: main
group: spine
plan_model: opus
impl_model: sonnet
---
Contract-side SDK. Usually a repin + regen.

- New host fns appear automatically on `env-common`'s `Env` trait once the env
  dep is re-pinned (they're generated from `env.json`); you then add a thin
  wrapper mirroring an existing one — typically ~5 lines, no special integration.
- **When bumping the env-common dep, drop the exact `=X.Y.Z` version pin** — the
  rev's package may self-report a different patch version. Keep major-version
  compatibility.
- If the host dropped a cargo feature this run, remove references to it here — a
  stale `soroban-env-*/cap_...` reference breaks the build.
- `check-git-rev-deps` failing because it points at an unmerged upstream PR is
  EXPECTED while the stack is in flight; note it, don't fight it.
