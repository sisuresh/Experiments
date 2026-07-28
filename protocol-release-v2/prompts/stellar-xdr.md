---
path: ~/dev/stellar-xdr
base: main
group: spine
plan_model: opus
impl_model: sonnet
---
Canonical XDR definitions — the single source for every other repo.

- Author the `.x` change on **`main`**, gated behind an `#ifdef` named after
  the CAP feature. The same flag token must be reused verbatim in every
  downstream repo (`--features`, rs-stellar-xdr `cap_<n>`, go/js `XDR_FEATURES`).
- The PR targets `main`. **Do not edit `curr`/`next`** — they regenerate.
- If the checkout is missing, clone it: `git clone https://github.com/stellar/stellar-xdr ~/dev/stellar-xdr`.
