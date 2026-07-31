---
path: ~/dev/go-stellar-sdk
base: protocol-next
group: leaf
plan_model: sonnet
plan_effort: medium
impl_model: sonnet
---
Single Go XDR provider for stellar-rpc, stellar-horizon and galexie. Base branch
is `protocol-next`, NOT main (basing on a release tag produces a 9-commit
reverting-everything diff).

- Bump `Makefile` `XDR_COMMIT` to the new `.x` SHA.
- Add `XDR_FEATURES ?= CAP_<n>_<TITLE>,...` and the
  `stellar-xdr xfile preprocess` step inside the `xdr/%.x` recipe — `goxdr` and
  Ruby `xdrgen` can't parse `#ifdef`.
- Drop `-it` from the Ruby `xdrgen` docker invocation (breaks in CI).
- `make xdr`, then commit the `Makefile`, the downloaded `xdr/*.x`, and all
  generated files (`xdr/`, `gxdr/`, `xdr/xdr_views_generated.go`).
- **Productionizing later (once this merges):** in each downstream `go.mod`,
  `go mod edit -dropreplace github.com/stellar/go-stellar-sdk` then
  `go get …@<merged-full-sha>` + `go mod tidy`. The `replace` and any
  SPIKE-only `gomoddirectives.replace-allow-list` exception are a pair — drop
  them together (present in `stellar-rpc/.golangci.yml`, absent in horizon).
- `update-completed-sprint` failing is a non-blocking tracker workflow.
