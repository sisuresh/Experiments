---
path: $REPO_ROOT/stellar-core
base: master
group: spine
plan_model: opus
impl_model: opus
plan_effort: high
impl_effort: high
---
C++ validator. Base branch is `master` (not main). Slowest, highest-risk repo.

### Per-protocol soroban submodule — CREATE `p<N>`, never bump `p<N-1>`
Core embeds a *separate* rs-soroban-env submodule per protocol
(`src/rust/soroban/p21`…`p<N-1>`) so old protocols keep replaying against their
original host. For protocol N: **create a new `src/rust/soroban/p<N>`** at the
CAP host commit, add its `.gitmodules` entry, and wire it into `Makefile.am`
multi-soroban linking mirroring `p<N-1>`. **Never touch the previous
protocol's submodule** — that targets the wrong protocol AND mutates released
behavior. Learn the add-pattern from `git log --oneline -- 'src/rust/soroban/p*'`.

### Protocol gating
- `Config::CURRENT_LEDGER_PROTOCOL_VERSION` in `src/main/Config.cpp`; named
  constants in `src/util/ProtocolVersion.h`. Gate CAP code with
  `protocolVersionStartsFrom(ledgerVersion, <X>_PROTOCOL_VERSION)`.
- A p28 bump may already be in from earlier CAP work — **do not duplicate it**.

### Build
- Configure next-protocol paths with
  `./configure --enable-next-protocol-version-unsafe-for-production`.
- **`make -j$(nproc)` — never bare `make -j`.** Unbounded `-j` spawns hundreds
  of compilers across the multi-version Rust soroban and hangs the machine.
- **Build INCREMENTALLY. Never `make clean` or a fresh build dir** — the
  in-tree build plus ccache turns a small edit into minutes instead of an hour.
- **`make format` before pushing** — CI enforces clang-format.
- If a compiler-cache wrapper (e.g. sccache via `RUSTC_WRAPPER`) fails to
  spawn, stop its server or unset the variable and rebuild — it is a local
  tooling problem, not a code failure.

### TxMeta baseline
CI checks committed `test-tx-meta-baseline-{current,next}`; a CAP that changes
tx semantics fails it by design. Re-record with
`stellar-core test [tx] --all-versions --rng-seed 12345 --record-test-tx-meta test-tx-meta-baseline-next`
(`-next` needs the vnext configure flag) and commit. Inspect the diff; if a tx
changed that you did NOT expect, flag it in the PR — but still commit and continue.

### Opening the PR
Core checkouts often accumulate many remotes (one per collaborator), which
breaks `gh pr create`'s head/base auto-resolution and yields a spurious `403`.
**A 403 here is a resolution artifact, not a permissions block** — the same
token opens cross-fork PRs on the other repos in the same run. Always use the
explicit form:
`gh pr create -R stellar/stellar-core --base master --head <fork-owner>:<branch> --draft`
(or set `GH_REPO=stellar/stellar-core`). **If it still fails, ESCALATE** — push
the branch and report the failing command. Never fall back to a fork-internal
PR or a synthetic base branch; those are invisible to upstream CI and reviewers.

### Downstream handoff
The `-vnext` deb + docker image comes from a manual Jenkins build *after* this
merges; horizon/rpc/quickstart legs block until it publishes.
