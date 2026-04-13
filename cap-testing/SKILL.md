---
name: cap-validate
description: Validate Stellar protocol changes (CAPs) end-to-end against a quickstart image. Reads a CAP spec, identifies what changed (XDR, operations, host functions, behavior), generates test scenarios, executes them against a running quickstart container, and validates that downstream dependencies (RPC, Horizon, SDKs, contracts) handle the changes correctly.
user-invocable: true
argument-hint: "<CAP number(s) or protocol change description> (e.g. '67', '67 68 74')"
---

# CAP Validation Skill

Validate that Stellar protocol changes work end-to-end — from core implementation through RPC, Horizon, SDKs, and contracts. Accepts one or more CAPs.

## When to use

- One or more CAPs are being implemented and you want to verify they work against a quickstart image
- A protocol upgrade is approaching and you want to validate all CAPs in the upgrade
- You want to regression-test existing protocol features against a new quickstart build
- You want to verify that a `nightly-next` image correctly supports the next protocol version

## Input format

This skill accepts multiple CAPs in any of these forms:

- Single CAP: `67` or `cap-0067`
- Multiple CAPs: `67 68 74` or `cap-0067 cap-0068 cap-0074`

When multiple CAPs are provided:
1. Analyze ALL of them first before generating any tests
2. Identify **interactions** between CAPs (e.g., one CAP adds a type that another CAP's host function uses)
3. Generate **shared baseline tests** once, then **per-CAP tests**, then **cross-CAP integration tests**
4. Report results grouped by CAP but flag cross-CAP issues prominently

gh api repos/stellar/stellar-protocol/contents/core --jq '.[].name' | grep '^cap-'

# For each, check the Protocol field in the header
# CAPs have a preamble like:
#   Protocol: 26
# Filter to those matching the target protocol version
```

## Prerequisites

### Stellar CLI

The `stellar` CLI is required. If it is not installed:

```bash
# Check if stellar CLI is available
which stellar

# If not found, install it:
# macOS / Linux
brew install stellar-cli
# If brew is not available:
cargo install --locked stellar-cli --features opt
```

If the CAP being tested requires CLI features that aren't in the released version (e.g., new subcommands, new transaction types, updated XDR support), check for a preview branch and build from source:

```bash
# Check for a preview or protocol-next branch
gh api repos/stellar/stellar-cli/branches --jq '.[].name' | grep -E 'preview|protocol-next|next'

# If one exists, build from that branch
cd $TMPDIR
git clone https://github.com/stellar/stellar-cli.git
cd stellar-cli
git checkout protocol-next  # or whatever the branch is called
cargo install --locked --path cmd/stellar-cli --features opt

# Verify the installed version
stellar --version
```

Report which CLI version/branch was used — like the SDK, this is release-readiness signal.

After installation, configure the local network:

```bash
stellar network add local \
  --rpc-url http://localhost:8000/soroban/rpc \
  --network-passphrase "Standalone Network ; February 2017"
```

### Quickstart container

A running quickstart container with the target protocol version. The correct image is determined in Phase 0 based on the target protocol. If one isn't running:

```bash
# Use the image determined in Phase 0 (nightly or nightly-next)
docker run --rm -it -p 8000:8000 -p 11626:11626 --name stellar stellar/quickstart:$IMAGE_TAG --local
```

Wait for health before proceeding:
```bash
curl -s http://localhost:8000/soroban/rpc -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' | jq .result.status
# Should return "healthy"
```

## Operating Procedure

### Phase 0: Determine target protocol version

Before doing anything else, ask the user which protocol version they are targeting. This determines which quickstart image to use and which CAPs to validate.

```
Ask: Which protocol version are you targeting? (e.g. 22, 23, 26)
```

Once you know the target protocol version:

1. **Determine the current released protocol** by checking the `nightly` quickstart image:
   ```bash
   # Pull and briefly run nightly to check its protocol version
   docker run --rm -d -p 8000:8000 --name stellar-check stellar/quickstart:nightly --local
   # Wait for health, then:
   curl -s http://localhost:8000/soroban/rpc -X POST -H 'Content-Type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"getLatestLedger"}' | jq .result.protocolVersion
   docker stop stellar-check
   ```

2. **Choose the quickstart image**:
   - If the target protocol version **matches** the `nightly` image's protocol → use `stellar/quickstart:nightly`
   - If the target protocol version is **higher** than what `nightly` supports → use `stellar/quickstart:nightly-next`
   - If the target protocol version is **lower** than `nightly` → the protocol is already released; `nightly` should still work but note this in the report

3. Start the chosen container (see Prerequisites section).

### Phase 1: Analyze the protocol changes

For each CAP number, fetch and read the spec:

```bash
# Single CAP
gh api repos/stellar/stellar-protocol/contents/core/cap-NNNN.md --jq .content | base64 -d

# For all-for-protocol-N, iterate over all CAP files and filter by Protocol field
```

For **each** CAP, extract:

1. **New or modified XDR types** — new operations, ledger entries, result types, config settings
2. **New host functions** — additions to the Soroban host environment (env.crypto, env.storage, etc.)
3. **Behavior changes** — modifications to existing operations, fee structure, limits, validation rules
4. **Configuration changes** — new network config settings, Soroban settings, protocol limits
5. **Deprecations** — features removed or marked for removal

Then, if multiple CAPs are being validated, perform **cross-CAP analysis**:

- **Dependencies**: Does CAP-A add an XDR type that CAP-B's host function uses?
- **Conflicts**: Do two CAPs modify the same operation or config setting?
- **Combined effects**: Does the combination of changes enable functionality that neither CAP enables alone?
- **Ordering**: Are there CAPs that must be tested before others (e.g., XDR changes before host functions that use those types)?

Classify each change by which downstream components it affects:

| Change Type | Affects |
|-------------|---------|
| New XDR operation | Core, Horizon (ingestion + API), RPC (simulation), SDKs (transaction building) |
| New host function | Core, RPC (simulation), Soroban SDK (contract code) |
| New ledger entry type | Core, Horizon (ingestion), RPC (getLedgerEntries), SDKs (XDR parsing) |
| Behavior change to existing op | Core, possibly Horizon/RPC if response format changes |
| New config setting | Core (sorobansettings), RPC (config queries) |
| XDR schema change | Everything — SDKs, RPC, Horizon all parse XDR |

### Phase 2: Generate test scenarios

For each identified change, generate test scenarios that validate the full path. Scenarios should cover:

#### 2a. Core validation — Does the feature exist and execute?

##### Resolving the Soroban SDK version

Before writing any contract code, determine what SDK to use. The released `soroban-sdk` on crates.io may not support the protocol features being tested yet.

**Step 1: Check crates.io for the latest release AND any release candidate (RC) versions:**

```bash
# Check all recent versions including RCs
curl -sL "https://crates.io/api/v1/crates/soroban-sdk/versions" | \
  python3 -c "import sys,json; [print(v['num']) for v in json.load(sys.stdin)['versions'][:15] if not v['yanked']]"

# Also check soroban-env-common for RC versions (host function definitions live here)
curl -sL "https://crates.io/api/v1/crates/soroban-env-common/versions" | \
  python3 -c "import sys,json; [print(v['num']) for v in json.load(sys.stdin)['versions'][:15] if not v['yanked']]"
```

RC packages (e.g., `26.0.0-rc.1`) often contain the new protocol features before the final release. If an RC exists for the target protocol version, prefer it over cloning from source.

**Step 2: Check if a `protocol-next` branch exists on rs-soroban-sdk:**

```bash
gh api repos/stellar/rs-soroban-sdk/branches/protocol-next --jq .name 2>/dev/null
```

**Step 3: Choose the right dependency based on what's available (in priority order):**

```toml
# Option A: RC version on crates.io supports the target protocol — use it
[dependencies]
soroban-sdk = "26.0.0-rc.1"

[dev-dependencies]
soroban-sdk = { version = "26.0.0-rc.1", features = ["testutils"] }

# Option B: released stable version already supports the feature — use crates.io
[dependencies]
soroban-sdk = "25.0.1"

# Option C: protocol-next branch exists — use it
[dependencies]
soroban-sdk = { git = "https://github.com/stellar/rs-soroban-sdk", branch = "protocol-next" }

[dev-dependencies]
soroban-sdk = { git = "https://github.com/stellar/rs-soroban-sdk", branch = "protocol-next", features = ["testutils"] }
```

**Step 4: If none of the above have the feature**, clone the SDK locally and add what's needed:

```bash
# Clone the SDK (or the env repo if the change is at the host function level)
cd $TMPDIR
git clone https://github.com/stellar/rs-soroban-sdk.git
cd rs-soroban-sdk

# Start from protocol-next if it exists, otherwise main
git checkout protocol-next 2>/dev/null || git checkout main
```

Then make the minimal changes needed to expose the new feature:

- **New host function**: The host function registry lives in `stellar/rs-soroban-env` in `soroban-env-common/env.json`. Clone that repo too if needed, add the function entry, and point the SDK at your local env:
  ```bash
  cd $TMPDIR
  git clone https://github.com/stellar/rs-soroban-env.git
  # Add the new host function to soroban-env-common/env.json
  # Then in rs-soroban-sdk, patch Cargo.toml to use the local env:
  ```
  ```toml
  # In rs-soroban-sdk/Cargo.toml, add:
  [patch."https://github.com/stellar/rs-soroban-env"]
  soroban-env-host = { path = "../rs-soroban-env/soroban-env-host" }
  soroban-env-guest = { path = "../rs-soroban-env/soroban-env-guest" }
  soroban-env-common = { path = "../rs-soroban-env/soroban-env-common" }
  ```

- **New SDK wrapper**: Add a high-level method in the SDK that calls the host function, following the patterns of existing methods (e.g., look at how `env.crypto().sha256()` wraps the underlying host call).

- **New types**: Add the type to the SDK so contracts can use it naturally.

Then point your test contract at the local SDK:

```toml
# In the test contract's Cargo.toml
[dependencies]
soroban-sdk = { path = "/path/to/rs-soroban-sdk/soroban-sdk" }

[dev-dependencies]
soroban-sdk = { path = "/path/to/rs-soroban-sdk/soroban-sdk", features = ["testutils"] }
```

**Report what changes were needed** — this is a key output of the validation. The diff you made to the SDK is effectively a draft of what the SDK team needs to ship before the protocol upgrade. Include it in the report:

```
### SDK Changes Required (rs-soroban-sdk)
- Added host function `new_crypto_function` to env.json (module: "crypto", protocol: 26)
- Added `Env::crypto().new_function()` wrapper in soroban-sdk/src/crypto.rs
- Diff: <link or inline>
```


**Always report which approach was used** — this is part of the validation output:

| SDK Approach | What it tells us |
|-------------|-----------------|
| Released crates.io version works | Feature is release-ready from SDK perspective |
| RC (release candidate) version on crates.io works | SDK support exists and is in pre-release — nearly ready |
| `protocol-next` branch required | SDK support exists but isn't released yet |
| Local SDK clone with modifications | SDK needs specific changes — include the diff as a deliverable |
| Contract won't compile with any approach | Host function may not be implemented in core yet, or signature is wrong |

##### Writing and deploying the test contract

For **new host functions**, write a minimal Soroban contract that calls the function:

```bash
# Initialize a contract project in a temp directory
cd $TMPDIR && stellar contract init cap-test-contract
```

Write a contract in `cap-test-contract/contracts/test/src/lib.rs` that exercises the new feature. Build and deploy:

```bash
cd $TMPDIR/cap-test-contract
stellar contract build
stellar contract deploy \
  --wasm target/wasm32-unknown-unknown/release/test.wasm \
  --source alice \
  --network local
```

Invoke the function and verify it returns the expected result:

```bash
stellar contract invoke --id $CONTRACT_ID --source alice --network local -- test_function --arg1 value1
```

For **new operations**, build and submit a transaction using the stellar CLI or SDK that includes the new operation.

For **behavior changes**, build a transaction that exercises the changed behavior and verify the new outcome differs from the old.

#### Important: Handling resource/simulation failures from the CLI

When `stellar contract deploy` or `stellar contract invoke` fails with resource-related errors (CPU instructions exceeded, memory limit, read/write bytes, etc.), **do NOT retry with `--instructions` or any resource-bumping flags**. These failures are signal, not noise.

Instead, report the failure with full detail:

```
| Test | Component | Status | Details |
| Deploy contract | Core | FAIL | Resource error: CPU instructions exceeded (used: 52_000_000, limit: 40_000_000) |
```

Resource failures can mean:
- **The new feature is more expensive than expected** — the CAP's cost model may need adjustment
- **Soroban settings on the network are too restrictive** — the quickstart image's config settings may not account for the new feature
- **The contract is doing something wrong** — the test contract may need to be simplified

Always capture and report the simulation cost breakdown from the CLI output or RPC `simulateTransaction` response:
```bash
# Get simulation details for a contract invocation
stellar contract invoke --id $CONTRACT_ID --source alice --network local --sim-only -- test_function --arg1 value1
```

Report the resource usage in the results:
```
Simulation resources:
  CPU instructions: 52,000,000 / 40,000,000 (EXCEEDED)
  Memory bytes: 1,200,000 / 40,000,000
  Read bytes: 2,000 / 200,000
  Write bytes: 500 / 65,536
  Ledger entries read: 5 / 40
  Ledger entries written: 2 / 25
```

This data is critical for protocol designers to understand the real-world cost of new features.

#### 2b. RPC validation — Does RPC correctly handle the change?

Test each relevant RPC method:

```bash
RPC_URL="http://localhost:8000/soroban/rpc"

# getHealth — baseline
curl -s $RPC_URL -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' | jq .

# getLatestLedger — confirm protocol version
curl -s $RPC_URL -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getLatestLedger"}' | jq .result.protocolVersion

# simulateTransaction — does simulation work for the new feature?
# Build a transaction XDR that uses the new feature, then:
curl -s $RPC_URL -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"simulateTransaction","params":{"transaction":"'$TX_XDR'"}}' | jq .

# getLedgerEntries — can we read new ledger entry types?
# If the CAP adds new ledger entries, query for them after creating one.

# getEvents — are events from the new feature correctly emitted?
curl -s $RPC_URL -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getEvents","params":{"startLedger":'$LEDGER',"filters":[{"type":"contract","contractIds":["'$CONTRACT_ID'"]}]}}' | jq .
```

#### 2c. Horizon validation — Does Horizon ingest and expose the change?

```bash
HORIZON_URL="http://localhost:8000"

# Check Horizon is ingesting
curl -s $HORIZON_URL/ | jq '{latest_ledger: .history_latest_ledger, protocol: .current_protocol_version}'

# After submitting a transaction that uses the new feature:
# Check the transaction appears in history
curl -s $HORIZON_URL/transactions/$TX_HASH | jq '{successful: .successful, operation_count: .operation_count}'

# Check operations are correctly typed
curl -s $HORIZON_URL/transactions/$TX_HASH/operations | jq '.._embedded.records[] | {type: .type, type_i: .type_i}'

# Check effects are generated
curl -s $HORIZON_URL/transactions/$TX_HASH/effects | jq '.._embedded.records[] | {type: .type}'
```

#### 2d. SDK validation — Can SDKs build transactions with the new feature?

If the CAP adds new operations or XDR types, verify the JS SDK can construct them. Write a small Node.js script:

```javascript
const StellarSdk = require("@stellar/stellar-sdk");
const rpc = new StellarSdk.rpc.Server("http://localhost:8000/soroban/rpc");

// Build a transaction using the new feature
// Parse the response
// Verify XDR round-trips correctly
```

For Soroban SDK changes, verify the Rust SDK exposes the new functionality by writing and compiling a contract that uses it.

#### 2e. Cross-component validation — Does the full chain work?

The most important test: exercise the new feature through the entire stack in sequence:

1. **Build** a transaction/contract using the SDK
2. **Submit** via RPC
3. **Query** the result via RPC (getTransaction, getLedgerEntries)
4. **Verify** Horizon ingested it correctly (operations, effects)
5. **Confirm** events were emitted and are queryable

### Phase 3: Execute and report

Run all scenarios and collect results. **Write the report to a file** in the current working directory named `P<N>-validation-report.md` (e.g., `P26-validation-report.md`). Structure the report as follows:

```
## Validation Report: Protocol <N> CAP Validation

### Environment
- Quickstart image: stellar/quickstart:<tag>
- Protocol version: <N>
- Core version: <version>
- RPC version: <version>
- Horizon version: <version>
- CAPs validated: CAP-NNNN, CAP-MMMM, ...

### Baseline Results

| Test | Status | Details |
|------|--------|---------|
| Environment health | PASS | Core synced, RPC healthy, Horizon ingesting |
| Classic payment | PASS | XLM transfer succeeded |
| Contract deploy + invoke | PASS | Hello world contract working |
| SAC interaction | PASS | Native asset wrapped |

### Per-CAP Results

#### CAP-NNNN — [Title]

| Test | Component | Status | Details | Lab |
|------|-----------|--------|---------|-----|
| Deploy contract using new host fn | Core | PASS | Contract deployed at C... | [tx](http://localhost:8000/lab/transactions-explorer/tx/{deploy_tx_hash}) |
| Invoke new host function | Core + RPC | PASS | Returned expected value | [tx](http://localhost:8000/lab/transactions-explorer/tx/{invoke_tx_hash}) |
| Simulate transaction | RPC | PASS | Simulation succeeded, cost: ... | |
| getLedgerEntries for new type | RPC | FAIL | Error: unknown ledger entry type | |
| Transaction in Horizon history | Horizon | PASS | Correctly ingested | [tx](http://localhost:8000/lab/transactions-explorer/tx/{tx_hash}) |
| Operation type in Horizon | Horizon | FAIL | Shows as "unknown" type | |
| SDK can build transaction | JS SDK | PASS | XDR round-trips correctly | [xdr](http://localhost:8000/lab/xdr/view) |
| Full chain: build→submit→query | All | PARTIAL | RPC ok, Horizon missing effect type | [tx](http://localhost:8000/lab/transactions-explorer/tx/{tx_hash}) |

#### CAP-MMMM — [Title]

| Test | Component | Status | Details | Lab |
|------|-----------|--------|---------|-----|
| ... | ... | ... | ... | ... |

### Cross-CAP Integration Results
(Only present when multiple CAPs are validated)

| Test | CAPs | Component | Status | Details |
|------|------|-----------|--------|---------|
| Contract uses host fn from CAP-A on type from CAP-B | A + B | Core | PASS | Combined feature works |
| ... | ... | ... | ... | ... |

### Summary

| CAP | Core | RPC | Horizon | SDK | Overall |
|-----|------|-----|---------|-----|---------|
| CAP-NNNN | PASS | PARTIAL | FAIL | PASS | FAIL |
| CAP-MMMM | PASS | PASS | PASS | PASS | PASS |
| Cross-CAP | PASS | PASS | — | — | PASS |

### Issues Found
1. **[CAP-NNNN][RPC]** getLedgerEntries returns error for new ConfigSetting type — likely needs RPC update
2. **[CAP-NNNN][Horizon]** New operation renders as "unknown" in operations endpoint — needs Horizon schema update

### Recommendations
- RPC needs protocol-next branch updated to handle new ledger entry type
- Horizon needs new operation type mapping before protocol upgrade
- Cross-CAP interaction between NNNN and MMMM works correctly, no additional action needed
```

## Scenario Templates

### Template: New Soroban Host Function

When a CAP adds a new function to the Soroban host environment:

1. Write a minimal contract that calls the new function
2. Build with `stellar contract build`
3. Deploy to local network
4. Invoke the function, verify return value
5. Check RPC simulation works
6. Check events if applicable

### Template: New Classic Operation

When a CAP adds a new Stellar operation type:

1. Build a transaction containing the new operation (via CLI or SDK)
2. Submit to local network
3. Verify transaction succeeded
4. Check Horizon shows the correct operation type and fields
5. Check Horizon effects
6. Verify SDK can parse the response XDR

### Template: Behavior Change to Existing Feature

When a CAP modifies how an existing feature works:

1. Build a transaction that would behave differently under old vs new protocol
2. Submit and verify the NEW behavior is observed
3. Build a transaction that tests the boundary/edge of the change
4. Verify error cases behave as specified
5. Check downstream components reflect the new behavior

### Template: New XDR Types

When a CAP adds or modifies XDR definitions:

1. Verify `stellar xdr encode/decode` handles the new types
2. Build a transaction or ledger entry using the new XDR
3. Submit and verify core accepts it
4. Query via RPC and verify the response decodes correctly
5. Query via Horizon and verify the response is correct
6. Test SDK XDR parsing of the new types

### Template: New/Modified Config Settings

When a CAP adds or changes network configuration:

1. Query current config via core: `curl -s http://localhost:11626/sorobansettings | jq .`
2. Verify the new setting exists and has the expected default
3. If the setting affects limits, test at the boundary (just under, at, just over)
4. Verify RPC exposes the setting correctly

## Baseline Tests

These tests should ALWAYS pass regardless of the specific CAP being validated. Run them first to ensure the quickstart environment is healthy before CAP-specific tests:

### 1. Environment health
```bash
# Core is synced
curl -s http://localhost:11626/info | jq .info.state
# RPC is healthy
curl -s http://localhost:8000/soroban/rpc -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' | jq .result.status
# Horizon is ingesting
curl -s http://localhost:8000/ | jq .history_latest_ledger
# Friendbot works
stellar keys generate --global test-baseline --network local --fund
```

### 2. Classic payment
```bash
stellar keys generate --global sender --network local --fund
stellar keys generate --global receiver --network local --fund
# Send XLM payment (use stellar CLI or curl to build/submit tx)
```

### 3. Contract deploy and invoke
```bash
cd $TMPDIR && stellar contract init baseline-test
# Write a simple hello-world contract
stellar contract build
stellar contract deploy --wasm target/wasm32-unknown-unknown/release/baseline_test.wasm --source test-baseline --network local
stellar contract invoke --id $CONTRACT_ID --source test-baseline --network local -- hello --to world
```

### 4. SAC (Stellar Asset Contract) interaction
```bash
# Wrap a classic asset into SAC and invoke via contract
stellar contract asset deploy --asset native --source test-baseline --network local
```

### 5. RPC query methods
```bash
# getLatestLedger, getHealth, getLedgerEntries, getEvents should all return valid responses
```

### 6. Horizon query methods
```bash
# /, /accounts/:id, /transactions, /operations should all return valid responses
```

## Failure Triage

When a test fails, classify the failure:

| Failure Pattern | Likely Cause | Action |
|----------------|--------------|--------|
| Contract build fails | Soroban SDK doesn't support new feature yet | Check soroban-sdk version, may need protocol-next branch |
| Deploy succeeds, invoke fails | Core accepts but can't execute | Check core logs, likely implementation bug |
| Core succeeds, RPC simulation fails | RPC doesn't understand new feature | Check stellar-rpc version, needs protocol-next update |
| RPC succeeds, Horizon shows "unknown" | Horizon schema not updated | Check stellar-horizon version, needs new type mapping |
| SDK can't build transaction | SDK XDR definitions outdated | Check stellar-sdk version, needs XDR update |
| Everything works but wrong values | Implementation bug | Compare against CAP spec, file issue on relevant repo |
| Timeout/hang | Resource exhaustion or deadlock | Check container resources, core logs |
| CPU instructions exceeded | New feature costs more than network allows | Report exact usage vs limit — do NOT add `--instructions` buffer. This is a signal that Soroban settings or the CAP's cost model may need adjustment |
| Memory/read/write bytes exceeded | Resource model mismatch | Report the full simulation cost breakdown. The network config may need updating for the new feature |
| Simulation succeeds but resources near limit | Potential fragility | Report as a warning — the feature works but may fail under slightly different conditions |

## Practical Notes

### Build each contract immediately after writing it

Do not write all contracts upfront and then build. SDK APIs may differ from what documentation or code search suggests (e.g., `MuxedAddress::from_string` takes 1 argument not 2, `Fr::from_u256` takes an owned value not a reference). Build each contract right after writing it, fix compilation errors, then move on.

### CLI XDR version can block config setting queries

The CLI's bundled XDR version may not include new `ConfigSettingID` variants added by the CAPs being tested. When this happens:
- `stellar xdr encode --type LedgerKey` will reject the new config setting names
- You cannot query these settings via the CLI or construct the RPC `getLedgerEntries` key
- This is itself a **finding** — report it as a CLI readiness gap

To work around this, build the CLI from source with updated XDR (see the CLI prerequisites section).

### Querying config settings

Config settings can be queried two ways — directly from core, or via RPC `getLedgerEntries`:

**Via core (simpler for browsing all settings):**
```bash
curl -s http://localhost:11626/sorobansettings | jq .
```

**Via RPC `getLedgerEntries` (for specific settings):**

```bash
# 1. Encode the config setting ledger key
KEY=$(echo '{"config_setting":{"config_setting_id":"state_archival"}}' | stellar xdr encode --type LedgerKey)

# 2. Query via RPC
curl -s http://localhost:8000/soroban/rpc -X POST -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getLedgerEntries\",\"params\":{\"keys\":[\"$KEY\"]}}"

# 3. Decode the response XDR
echo "<xdr from response>" | stellar xdr decode --type LedgerEntryData
```

### Docker disk space

The quickstart container needs disk space for PostgreSQL initialization. If the container exits immediately on startup, check `docker logs` — "No space left on device" during `initdb` means Docker's disk is full. Run `docker system prune` to reclaim space from old containers and images.

## Quick Reference

### Local network configuration
- RPC: `http://localhost:8000/soroban/rpc`
- Horizon: `http://localhost:8000`
- Core: `http://localhost:11626`
- Friendbot: `http://localhost:8000/friendbot`
- Lab: `http://localhost:8000/lab`
- Network passphrase: `Standalone Network ; February 2017`
- Network name (for CLI): `local`

### Stellar Laboratory URLs

The quickstart container runs the Stellar Laboratory at `http://localhost:8000/lab`. Include lab links in the report for every transaction submitted during validation so results can be visually inspected.

| What | URL pattern |
|------|-------------|
| Transaction details | `http://localhost:8000/lab/transactions-explorer/tx/{tx_hash}` |
| XDR viewer | `http://localhost:8000/lab/xdr/view` |
| Contract explorer | `http://localhost:8000/lab/smart-contracts/contract-explorer` |
| Account details | `http://localhost:8000/lab/account` |
| RPC endpoints | `http://localhost:8000/lab/endpoints/rpc` |
| Horizon endpoints | `http://localhost:8000/lab/endpoints/horizon` |

When reporting results, **always capture the transaction hash** from every deploy/invoke/submit and include the lab transaction explorer link. This lets the reader click through to see the full decoded transaction, operations, and effects in the lab UI without having to manually query.

**Note**: Read-only invocations (where the CLI says "Simulation identified as read-only") are not submitted on-chain and produce no transaction hash. Lab links are only available for state-changing calls. To force submission of a read-only call (e.g., to get a tx hash for the report), use `--send=yes`.

### Stellar CLI network setup
```bash
stellar network add local \
  --rpc-url http://localhost:8000/soroban/rpc \
  --network-passphrase "Standalone Network ; February 2017"
```

### Get image component versions
```bash
docker exec stellar cat /image.json | jq '{
  core: .core.ref,
  rpc: .rpc.ref,
  horizon: .horizon.ref,
  protocol: .protocol_version_default
}'
```

### Repo issue trackers
- Core bugs: `stellar/stellar-core`
- RPC bugs: `stellar/stellar-rpc`
- Horizon bugs: `stellar/stellar-horizon`
- SDK bugs: `stellar/js-stellar-sdk`
- Soroban SDK bugs: `stellar/rs-soroban-sdk`
- Protocol specs: `stellar/stellar-protocol`
