---
path: ~/dev/stellar-horizon
base: protocol-next
group: leaf
plan_model: opus
impl_model: opus
impl_effort: high
---
Horizon ingestion. Base branch is `protocol-next`, NOT main. Needs SEMANTIC
work, not just a regen — this is why it plans and implements on the frontier model.

- Bump the go-stellar-sdk dep to this run's pushed head.
- If the CAP changes what SAC/contract events carry, update
  `internal/ingest/contractevents/` accordingly. `TestCoreLCMIngestion` only
  asserts that ingestion doesn't error, so it will NOT catch a wrong or missing
  value — implement the semantic change and flag it for human review in the PR.
- Confirm `MaxSupportedProtocolVersion` (internal/ingest/main.go) is at the
  release protocol; only bump if earlier CAP work didn't already.
- Integration tests pin core docker images per protocol in
  `.github/workflows/horizon.yml`. If the base branch's pins are stale relative
  to main, the fix belongs on the BASE branch (merge main into protocol-next),
  not in this PR.
