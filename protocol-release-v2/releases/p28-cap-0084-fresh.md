# Protocol 28 — CAP-0084 (Muxed Contract Addresses) — CLEAN-SLATE RE-RUN

## Ground rules for this run (read these first — they override normal conventions)

This is an **uncontaminated second attempt** at CAP-0084. Earlier attempts exist
as PRs on these repos, open and closed. The entire point of this run is to
derive the design independently, so:

- **Do NOT read this repo's own prior CAP PRs**, in any state — open, closed, or
  merged. No `gh pr list` / `gh pr view` / `gh pr diff` / review comments on
  them. (Reading an *upstream* repo's PR to get a pin SHA is still fine; it is
  this repo's own previous attempts that are off-limits.)
- **Do NOT inspect, check out, or diff against any existing release branch**
  (e.g. a local or remote `p28-cap-0084`).
- **Plan and implement from the base branch as if this were the first attempt.**
  You are working in a throwaway worktree detached at the base branch, so the
  prior attempt's files are not present — do not go hunting for them elsewhere.
- **Commit locally only. Do NOT push. Do NOT open, update, comment on, or close
  any PR.** The result is meant to be diffed against the previous attempt by
  hand, not shipped.
- Because nothing is pushed, downstream repos cannot repin to an upstream from
  this run. Prefer running one repo at a time (`--only <repo>`); if a pin to an
  unlanded upstream is needed, state that in your plan rather than inventing one.
- Ignore the `Branch + PR naming` and cross-linking conventions from the shared
  conventions doc — they assume you are shipping a PR, and you are not.

Everything below describes the CAP itself and is unchanged.

## The release

- Protocol number: 28
- CAP: **CAP-0084** — Muxed Contract Addresses
  (https://github.com/stellar/stellar-protocol/pull/1968)
- CAPs dropped: (none)
- Release slug: `p28-cap-0084` (for a local branch name only — nothing is pushed)
- XDR feature flag token: `cap_0084_muxed_contract`
- Also in flight on the same base: **CAP-0085** (`cap_0085_executable_ref`),
  already merged to `main` in several repos. Any XDR rev this release pins must
  carry BOTH caps' features.

## XDR change

New `SC_ADDRESS_TYPE_MUXED_CONTRACT` arm on `SCAddress`:
`MuxedContract { uint64 id; ContractID contractId; }`, mirroring
`MuxedEd25519Account`. Lives in `Stellar-contract.x`.

## Scope

- Host (rs-soroban-env) is the real work: SAC `transfer` and `mint` accept a
  muxed-contract destination and emit it via the existing `to_muxed_id` event
  convention; `SC_ADDRESS_TYPE_MUXED_CONTRACT` is prohibited in contract
  storage keys.
- **Destination-only, transfer/mint only** (`transfer_from` deferred), matching
  CAP-67's precedent for muxed accounts. Reuse the existing
  `MuxedAddressObject` and its `get_address_from_muxed_address` /
  `get_id_from_muxed_address` accessors — **no new host functions**.
- Reject any plan that adds source muxing or new host functions.

## Targets (dependency order)

- stellar-xdr
- rs-stellar-xdr
- rs-soroban-env
- rs-soroban-sdk
- stellar-core
- go-stellar-sdk
- stellar-horizon
- stellar-rpc
- js-stellar-base
- js-stellar-sdk
- js-stellar-xdr-json
- stellar-laboratory
- docker-stellar-core-horizon

## Do not change

- Any unrelated Go / Rust / JS module bumps.
