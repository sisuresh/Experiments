---
path: $REPO_ROOT/js-stellar-sdk
base: master
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
Re-points its `@stellar/stellar-base` dep AND must rebuild its own browser
bundle. Default branch is **`master`**, not main.

- **After bumping `@stellar/stellar-base` you MUST `yarn build:browser`.**
  `package.json` declares `"browser": "./dist/stellar-sdk.min.js"` — a pre-built
  bundle that inlines stellar-base's XDR at SDK build time, and it's what
  webpack/Next.js consumers use, not `lib/`. Skip this and every browser
  consumer keeps seeing the OLD XDR (this was the real cause of a past "unknown
  SorobanCredentialsType value 3" in the lab).
- **`yarn add "github:user/repo#branch"` clones the source, not the published
  artifact** — `dist/`/`lib/` won't exist unless committed. For SPIKE branches
  use a local `file:` tarball from `yarn pack` after building.
- The `prepare` hook (`yarn build:prod`) may emit `TS7006: implicit any` against
  regenerated stellar-base types. `lib/` is committed so runtime is fine.
