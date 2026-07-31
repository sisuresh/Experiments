---
path: $REPO_ROOT/stellar-laboratory
base: main
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
Web app (repo is `stellar/laboratory`) depending on stellar-base, stellar-sdk and
stellar-xdr-json. Package manager is `pnpm@10.x` — `corepack enable && pnpm install --frozen-lockfile`.

- Re-pin all three deps to this run's heads, and add a `resolutions` entry for
  `@stellar/stellar-base` so transitive consumers see the same version.
- **`rm -rf .next build` between stellar-base reinstalls and `pnpm build`** —
  Next.js' production cache keeps the previous build's broken chunks even after
  `node_modules/` updates.
- **A `file:` tarball's content-addressable cache only invalidates on path
  change, not content.** After repacking the same filename, pnpm/yarn reuse the
  cached extract even after `cache clean`. Rename the tarball
  (`pack.tgz` → `pack-v2.tgz`) and update every `file:` ref.
- **Don't chase the duplicate `@stellar/stellar-sdk` that `@trezor/blockchain-link`
  pulls in** — it's in a separate webpack chunk the tx-render path never reaches.
  The real fix is js-stellar-sdk's own browser dist.
- After bumping, an `@ts-expect-error` in the transactions-explorer
  `TransactionDetails.tsx` may become unused — drop it or `pnpm build` fails on
  "Unused @ts-expect-error directive".
- Check the repo's own `CLAUDE.md`; UI surface for new XDR types is usually
  generated, so verify before hand-writing anything.
