# protocol-release-v2 (prototype)

A rewrite of `../protocol-release/loop.sh` on the **Claude Agent SDK** (Python).
Same job — ship a Stellar protocol upgrade as a stack of PRs across ~13 repos —
but the orchestration is ~340 lines of Python instead of ~1750 lines of bash,
because the agents now have real tools and do their own planning, building and
pushing.

Nothing here touches `../protocol-release`. That flow still works; this is a
parallel prototype.

## Run it

```bash
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt   # once

# Dry run (default): plan only, read-only tools, nothing written or pushed.
./.venv/bin/python author.py releases/p28-cap-0084.md --only rs-stellar-xdr
./.venv/bin/python author.py releases/p28-cap-0084.md          # plan every repo

# For real: agents edit, build, commit, push, open/update PRs.
./.venv/bin/python author.py releases/p28-cap-0084.md --write
./.venv/bin/python author.py releases/p28-cap-0084.md --write --from rs-soroban-env
```

Flags: `--only <repo>` one repo · `--from <repo>` resume mid-chain ·
`--write` actually change things · `--plan-only` force dry even with `--write`.

Auth uses your existing Claude Code login — no `ANTHROPIC_API_KEY` needed.

## The three ideas

**1. One file per repo.** `prompts/<repo>.md` holds that repo's config
(frontmatter: checkout path, base branch, spine/leaf, model + effort tiers) *and*
its custom prompt. Adding a repo is one new file; there is no central config to
edit in three places. Everything repo-specific — base-branch quirks, known
traps, "don't add feature gates here" — lives in its own prompt.

**2. Context is curated, not accumulated.**
- Each repo's **implementer resumes the planner's session** (`resume=`), so it
  inherits the plan and the repo exploration instead of paying to rediscover
  both. Verified working across a model switch (Opus → Sonnet).
- Downstream repos read a **3-line chain summary** (`prUrl @ headSha — notes`)
  built from upstream handoffs, not a re-exploration of five upstream repos.
  That summary persists in `state/<release>.json`, so it survives re-runs.
- `prompts/_base.md` is byte-identical across every agent, so it sits in the
  cacheable prefix of every prompt.

**3. Frontier model plans, cheaper model implements.** Per repo, `plan_model`
(default `opus`) produces an implementation-ready plan with no write tools;
`impl_model` (default `sonnet`) executes it. Effort is tiered the same way
(`plan_effort` / `impl_effort`, default `high`/`medium`). The two genuinely hard
repos — `rs-soroban-env` and `stellar-core` — run `opus/xhigh → opus/high`,
because that is exactly where XDR-pin reconciliation and semantic merge
conflicts live.

## Shape of the run

The dep chain is a **serial spine + parallel leaves**, not a flat fan-out:

- **spine** (`stellar-xdr → rs-stellar-xdr → rs-soroban-env → rs-soroban-sdk →
  stellar-core`) runs sequentially — each repin needs the previous repo's pushed
  head SHA. This also serializes the heavy Rust/C++ builds for free.
- **leaves** (go/horizon/rpc/js×3/lab/quickstart) run in parallel via
  `asyncio.gather(..., return_exceptions=True)` — they depend on the spine, not
  on each other, and one failure must not cancel its siblings.

## Files

| | |
|---|---|
| `author.py` | the driver: arg parsing, spine/leaf orchestration, plan→impl per repo |
| `lib.py` | agent runner (streaming, cost, structured output), prompt loading, state |
| `prompts/_base.md` | conventions every agent gets: branch/PR mechanics, pin discipline, output style |
| `prompts/<repo>.md` | per-repo config + custom prompt |
| `releases/<slug>.md` | the release: CAP scope, feature flag token, `## Targets` in dep order |
| `state/<slug>.json` | repo → `{prUrl, headSha, notes}`; resume record + chain context |
| `logs/<ts>/` | `run.log`, `cost.tsv`, and a full transcript per agent |

## What deliberately did NOT move here

The **watch phase** (poll CI for hours, fix reds) is still `loop.sh`'s job and
should stay a thin deterministic poller. Watching a 2-hour integration matrix is
a long-duration, low-intelligence task — a `sleep` loop is the right tool, not an
agent holding context. The genuinely load-bearing bits of the old script are all
in that phase: GitHub rate-limit pacing, the machine-wide build mutex, the
escalation counter.

## Status / caveats

- Verified against the installed SDK (0.2.128), not assumed: auth without an API
  key, `output_format` structured handoffs, `effort` per call, cost/usage
  logging, cross-model session resume, and a full plan-only run against
  `rs-stellar-xdr` (34 turns, ~$1.87, ~10 min).
- **Not yet verified: a real `--write` run.** No agent in this prototype has
  edited or pushed anything.
- `--write` runs agents with `bypassPermissions` (there is no human to approve
  each edit). Each agent is scoped to one checkout, but it can push and open
  PRs. Dry run is the default for that reason.
- Cost is not yet proven better than the bash flow. Planning one repo on Opus
  costs roughly what the old flow's whole per-repo refresh cost; the expected
  saving comes from Sonnet implementing against a resumed session, which is
  untested.
- `max_turns` (60 plan / 150 impl) is a guess, and `max_budget_usd` is wired but
  unset. Tune once real runs exist.
