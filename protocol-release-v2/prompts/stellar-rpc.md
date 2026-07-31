---
path: $REPO_ROOT/stellar-rpc
base: protocol-next
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
Two layers: Go (uses go-stellar-sdk like horizon) + Rust preflight
(`cmd/stellar-rpc/lib/{preflight,xdr2json}`). Base is `protocol-next`, NOT main.

- **Multi-protocol host: shift the window.** `-prev` ← what `-curr` pointed at;
  `-curr` ← the new host SHA. If you advance `-prev`, audit
  `lib/preflight/src/lib.rs prev::load_network_config` — the soroban-simulation
  API has drifted between versions under `unstable-next-api`.
- `cargo update -p ethnum` is needed once after the bump.
- Go side: same go-stellar-sdk re-pin as horizon.
- **`.github/workflows/stellar-rpc.yml`:** rpc has one `integration-p{N}-pkg`
  stanza per protocol, not a matrix axis. Add one for protocol N and drop the
  oldest. Use a `-vnext` core image, and a deb variant mirroring the *previous*
  leg's (plain → `~vnext`; `~buildtests` → `~vnext~buildtests`). Without the leg
  the new protocol's code paths are never exercised even on a green PR.
- **Protocol-versioned upgrade fixtures** under
  `internal/integrationtest/infrastructure/docker/upgrades/`
  (`unlimited.p{N}.{xdr,json}`, `testnet.p{N}.…`): a missing file short-circuits
  every test calling `NewTest()`. **Try copying the previous protocol's pair
  first**; only regenerate if the CAP changes Soroban `ConfigSettings`.
- The integration const `MaxSupportedProtocolVersion = 24` is NOT part of the
  protocol-bump pattern — leave it.
- **`dependency-sanity-checker` and the `complete` rollup fail by design during
  a protocol transition** (mixed dep sources, Go XDR leading Rust, missing
  `p{N}-expect.txt`). **Do NOT patch `scripts/check-dependencies.bash` to
  silence them** — the maintainer expects to see them and any "fix" papers over
  real divergences. Treat as non-blocking.
