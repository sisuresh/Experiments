---
path: $REPO_ROOT/docker-stellar-core-horizon
base: master
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
Quickstart image (repo is `stellar/quickstart`). `images.json` declares deps; the
Dockerfile has per-service build stages. Confirm the default branch.

- **Use full commit SHAs as `*_REF` build-args, never branch names** — Docker
  caches by build-arg value and will reuse stale layers after a force-push.
- Inherit from `nightly-next` in `images.json` and override only what differs.
- For iteration, build only changed binaries via
  `--target stellar-{core,rpc,horizon}-builder` and layer them onto
  `nightly-next` with a tiny `COPY --from=…` Dockerfile — a full `make build` is
  ~an hour.
- **Wait for the core artifact whose embedded commit matches the core PR's HEAD**
  — a mismatched-commit artifact is the usual cause of a red build here. `-vnext`
  builds are tagged with a `-vnext` **suffix** on the base release version, not
  `N.x.x`, so searching tags by protocol number finds nothing. Mirror the
  previous protocol's variant (plain vs `~buildtests`). If it hasn't published,
  say so rather than pinning something wrong.
```
curl -s "https://hub.docker.com/v2/repositories/stellar/unsafe-stellar-core/tags/?page_size=100&name=vnext" | jq -r '.results[].name'
curl -s https://apt.stellar.org/pool/unstable/s/stellar-core/ | grep -oE 'stellar-core[^"<]*\.deb'
```
- `etc/config-settings/p<N>/` only goes up to p26; Soroban limits fall back to
  the nearest lower dir, or pass `--limits default`.
