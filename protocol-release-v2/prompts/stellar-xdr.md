---
path: $REPO_ROOT/stellar-xdr
base: main
group: spine
plan_model: opus
impl_model: sonnet
---
Canonical XDR definitions — the single source for every other repo.

- All edits go on **`main`**. `curr` (no features) and `next` (all features) are
  auto-generated from `main` by a GitHub Action on every push — **never commit
  to `curr`/`next`**.
- **Gate each new CAP definition behind `CAP_<n>_<SHORT_TITLE>`** — e.g.
  `#ifdef CAP_0084_MUXED_CONTRACT`, not a bare `CAP_0084`. The bare flags
  already in the `.x` files are **legacy; do not copy that style**. The title
  makes the token self-documenting everywhere it surfaces downstream.
- The token you choose here is the verbatim contract for every downstream
  `--features` / `XDR_FEATURES` / crate feature.
- Anything transitively touching `LedgerEntry` / `LedgerHeader` /
  `TransactionEnvelope` / `StellarValue` stays gated until core bumps its max
  supported protocol.
- **One `.x` commit feeds every consumer.** Rust (rs-stellar-xdr) and C++
  (core's `src/protocol-curr/xdr` submodule) regen from the SAME commit. If one
  language needs a change (e.g. reordering a definition so `xdrpp` compiles), it
  goes in that one shared commit and every consumer re-pins. Never author a side
  `.x` on a fork, and never repoint core's submodule at one — it diverges C++
  from Rust and fails core's byte-level `XDR_FILES_SHA256`.
- If the checkout is missing, clone it to the path above:
  `git clone https://github.com/stellar/stellar-xdr "$REPO_ROOT/stellar-xdr"`.
- `stellar-xdr xfile preprocess --features CAP_<n>,...` is the canonical way to
  resolve `#ifdef` before any non-Rust codegen (`goxdr` and Ruby `xdrgen` both
  choke on `#`).
