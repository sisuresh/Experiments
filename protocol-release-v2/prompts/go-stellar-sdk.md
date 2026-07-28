---
path: ~/dev/go-stellar-sdk
base: protocol-next
group: leaf
plan_model: opus
impl_model: sonnet
---
Go SDK. Base branch is `protocol-next`, NOT main.

- Regenerate Go XDR with the release's `XDR_FEATURES` set to the same flag
  token used upstream.
- `update-completed-sprint` failing is a non-blocking tracker workflow — ignore it.
