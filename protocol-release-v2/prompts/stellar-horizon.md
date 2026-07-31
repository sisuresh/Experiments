---
path: ~/dev/stellar-horizon
base: protocol-next
group: leaf
plan_model: opus
impl_model: opus
impl_effort: high
---
Horizon ingestion. Base branch is `protocol-next`, NOT main. Needs SEMANTIC
work, not just a regen — hence the frontier model on both halves.

- `internal/ingest/main.go`: bump `MaxSupportedProtocolVersion` (only if earlier
  CAP work didn't already).
- Re-pin the go-stellar-sdk dep to this run's pushed head.
- If the CAP changes what SAC/contract events carry, update
  `internal/ingest/contractevents/`. **`TestCoreLCMIngestion` only asserts that
  ingestion doesn't error**, so it will NOT catch a wrong or missing value —
  implement the semantic change and flag it for human review in the PR.
- **`.github/workflows/horizon.yml` matrix:** add protocol N AND drop the oldest
  (rolling window of two). Add the matching
  `PROTOCOL_N_CORE_DOCKER_IMG` / `_CORE_DEBIAN_PKG_VERSION` /
  `_STELLAR_RPC_DOCKER_IMG` env block using a **`-vnext`** core image. Without
  this the PR isn't validating protocol N at all.
- **If no protocol-N stellar-rpc image is published, leave
  `PROTOCOL_N_STELLAR_RPC_DOCKER_IMG: ""`** and guard the pull step against an
  empty value, so `NewTest()`'s AMBER skip fires. Do NOT reuse the previous
  protocol's RPC image — it bundles a previous-protocol captive-core that cannot
  ingest the new protocol, so every `EnableStellarRPC` test hangs in
  `waitForStellarRPC()` until the 75m suite timeout kills the run.
- **Protocol-versioned testdata** under `internal/integration/testdata/`
  (`unlimited-config-v{N}.xdr`, `load-test-*-v{N}.*`): a missing file kills every
  test calling `NewTest()`. **Try copying the previous protocol's file first** —
  if the CAP doesn't change what the file encodes, the byte-identical copy works.
  Only regenerate when it actually does.
- If the base branch's core image pins are stale relative to `main`, the fix
  belongs on the BASE branch (merge main into protocol-next), not in this PR.

### Waiting on core artifacts
`-vnext` images are tagged with a `-vnext` **suffix** on the base release
version, not `N.x.x` — searching tags for the protocol number returns nothing.
The `<commit>` token must be a prefix of the core PR's HEAD SHA; pin that build,
not the newest `-vnext`. Mirror the *previous* protocol leg's variant (plain vs
`~buildtests`) — assertion overhead from `~buildtests` makes timing-sensitive
tests miss deadlines.
```
curl -s "https://hub.docker.com/v2/repositories/stellar/unsafe-stellar-core/tags/?page_size=100&name=vnext" | jq -r '.results[].name'
curl -s https://apt.stellar.org/pool/unstable/s/stellar-core/ | grep -oE 'stellar-core[^"<]*\.deb'
```
