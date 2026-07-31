---
path: $REPO_ROOT/js-stellar-base
base: master
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
The actual JS XDR codec — drives both `@stellar/stellar-sdk` and the laboratory's
runtime decoding. Default branch is **`master`**, not main.

- Bump `XDR_BASE_URL_{CURR,NEXT}` in the Makefile to the new `.x` SHA.
- Add `stellar-xdr xfile preprocess --features CAP_<n>_<TITLE>,...` before the
  Ruby `xdrgen` step (`xdrgen` can't parse `#ifdef`).
- Drop `-it` from `docker run` invocations (breaks in CI).
- The dts-xdr step uses `node:alpine`, which no longer ships yarn — switch to
  `node:lts-alpine` and `apk add --update yarn` in the same step.
- **Post-processing must INLINE `xdr.const` values at every usage site.** xdrgen
  emits bare identifiers like `xdr.string(SCSYMBOL_LIMIT)`, but js-xdr's
  `TypeBuilder.const()` doesn't put the name in the calling scope. Injecting
  `var SCSYMBOL_LIMIT = 32;` looks right in the dev build but **terser's DCE
  strips it from the production browser dist**. Instead: collect every
  `xdr.const("NAME", N)` in `src/generated/{curr,next}_generated.js` and
  substitute each remaining bare `\bNAME\b` with the literal `N`.
- `next.d.ts` may fail in the dts-xdr step (prettier missing in the container).
  Not blocking — runtime is `.js`, types are dev-time only.
- If the CAP adds an address/type variant, hand-written helpers (strkey handling,
  type guards) usually accompany the regen — mirror the previous CAP's.
