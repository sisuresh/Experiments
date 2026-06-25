#!/usr/bin/env bash
# protocol-release-loop.sh — drive a Stellar protocol-release PR stack
# end-to-end using two models: claude plans/executes, copilot+gpt reviews.
#
# Single invocation processes every in-scope repo:
#   1. OPEN phase  — for each repo in dep order: plan_then_review →
#                    claude opens a draft PR. PR URLs recorded in state.
#   2. WATCH phase — outer loop polls every open PR. On red, plan_then_review
#                    gets cross-PR context (every open PR + current statuses).
#                    The planner can route the fix to ANY open PR, including
#                    an upstream — claude `cd`s to the right repo and pushes.
#                    Watch continues until all PRs green, all PRs escalate,
#                    or MAX_WATCH_ITERS hit.
#
# Contract + lessons docs (both models read these on every prompt):
#   Live next to this script. The CONTRACT env var can override the
#   contract path; lessons is hardcoded to `lessons.md` in the same dir.
#
# Inputs file format (plain markdown). The script parses ONE block:
#
#   ## Targets   — repos the operator wants PRs against this run.
#                  Listed in dep order, top-down. Drives Phase 1.
#
# Everything else (protocol number, stellar-xdr commit, CAP feature flag
# changes, base-branch notes, "don't touch X" caveats) is freeform prose
# the planner + reviewer read directly.
#
#   # Protocol N — <CAPs>
#   Protocol number: N
#   stellar-xdr commit: <sha>
#   Feature flags enable: CAP_XXXX
#   Feature flags drop:   CAP_YYYY
#
#   ## Targets (dep order, top-down)
#   - /Users/.../stellar-horizon
#   - /Users/.../stellar-rpc
#
#   ## Notes
#   <freeform — base branches, pins to keep unchanged, etc>
#
# Upstream PRs the planner decides are needed (e.g. horizon CI fails →
# the fix belongs in go-stellar-sdk) are opened on the fly by claude
# during the watch phase. The script harvests any new PR URLs from
# claude's output and adds them to the watched set. The operator never
# needs to list upstream repos — the dep chain is in the contract doc
# and claude has shell access to clone/edit anywhere it needs.
#
# Usage:
#   protocol-release-loop.sh <inputs-file>
#
# Env knobs (all optional):
#   CONTRACT          Path to the contract doc. Default: contract.md next to
#                     this script.
#   CLAUDE_MODEL      Claude model for the planner/executor (default:
#                     claude-opus-4-8). Aliases like 'opus' / 'sonnet' also work.
#   REVIEWER_MODEL    Copilot model (default: gpt-5.5). Other GPTs on this
#                     account: gpt-5.4, gpt-5.3-codex, gpt-5.4-mini, gpt-5-mini.
#   MAX_WATCH_ITERS   Cap on outer-loop iterations in watch phase (default: 60).
#                     With WATCH_INTERVAL=120 that gives ~2 hours of polling,
#                     which covers most slow CI matrices (horizon integration
#                     tests, full Rust+Cargo builds, multi-protocol runs).
#   WATCH_INTERVAL    Sleep between watch passes, seconds (default: 120)
#   MAX_REVIEW_ROUNDS Plan-revise rounds in plan_then_review (default: 3).
#   MAX_INVESTIGATE_ROUNDS  Cap on INVESTIGATE verdicts before forcing a
#                     decision (default: 3).
#   MAX_SAME_FAIL_RETRIES   Same-signature retries before ESCALATE (default: 3).
#   IGNORED_CHECKS    Comma-separated check names treated as non-blocking when
#                     polling PR CI. These are checks that legitimately fail
#                     on protocol-next PRs and shouldn't drag the watch loop
#                     into plan-review (e.g. `dependency-sanity-checker` fails
#                     during a transition by design; the rollup workflow
#                     `complete` fails as a consequence). Default:
#                     dependency-sanity-checker,complete
#   STATE_DIR         Persistent state across runs.
#                     Default: ${XDG_STATE_HOME:-$HOME/.local/state}/protocol-release-loop
#   LOG_DIR           Per-run logs.
#                     Default: ${XDG_DATA_HOME:-$HOME/.local/share}/protocol-release-loop/logs
#   WORK_DIR          Where claude can clone repos not already present locally.
#                     Default: $STATE_DIR/clones

set -euo pipefail

# Resolve the script's own directory (portable, doesn't follow symlinks).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUTS="${1:?usage: $0 <inputs-file>}"
CONTRACT="${CONTRACT:-$SCRIPT_DIR/contract.md}"
LESSONS="$SCRIPT_DIR/lessons.md"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"
REVIEWER_MODEL="${REVIEWER_MODEL:-gpt-5.5}"
MAX_WATCH_ITERS="${MAX_WATCH_ITERS:-60}"
WATCH_INTERVAL="${WATCH_INTERVAL:-120}"
# Cap on plan-revise rounds inside plan_then_review (was 2; 3 gives the
# reviewer one extra chance to push back before the script commits).
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"
# Cap on consecutive INVESTIGATE verdicts before forcing a SKIP/FIX
# decision. INVESTIGATE lets the planner take extra turns reading code
# before producing a fix; cap prevents indefinite digging.
MAX_INVESTIGATE_ROUNDS="${MAX_INVESTIGATE_ROUNDS:-3}"
# Number of times the SAME failure signature is allowed to repeat on a
# PR before the script marks it ESCALATED. Was 1 (escalate on 2nd
# occurrence); 3 lets the planner try 3 fixes for the same signature
# before giving up.
MAX_SAME_FAIL_RETRIES="${MAX_SAME_FAIL_RETRIES:-3}"
# CI checks that legitimately fail on protocol-next PRs and shouldn't block
# the watch loop from declaring a PR green or trigger plan-review:
#   - dependency-sanity-checker: enforces steady-state invariants (single
#     source per crate@version, exact Go/Rust stellar-xdr match, p{N}-expect.txt
#     present) that are temporarily violated mid-transition. Failure is
#     expected during a protocol-next bump.
#   - complete: the rollup workflow that aggregates required-status-check
#     results; if dependency-sanity-checker is among its required inputs,
#     it fails as a consequence.
# Build a JSON array form for jq's --argjson.
IGNORED_CHECKS="${IGNORED_CHECKS:-dependency-sanity-checker,complete}"
IGNORED_CHECKS_JSON="$(printf '%s' "$IGNORED_CHECKS" | jq -R 'split(",") | map(select(length > 0))')"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/protocol-release-loop}"
LOG_DIR="${LOG_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/protocol-release-loop/logs}"
WORK_DIR="${WORK_DIR:-$STATE_DIR/clones}"

# --- Preflight ---
for cmd in claude copilot gh git jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not on PATH" >&2; exit 1; }
done
[[ -f "$INPUTS" ]] || { echo "ERROR: inputs file not found: $INPUTS" >&2; exit 1; }
[[ -f "$CONTRACT" ]] || { echo "ERROR: contract doc missing: $CONTRACT" >&2; exit 1; }
[[ -f "$LESSONS" ]] || { echo "ERROR: lessons doc missing: $LESSONS" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated" >&2; exit 1; }

# Portable sha1 (shasum on macOS, sha1sum on Linux, either is fine).
if command -v shasum >/dev/null 2>&1; then
  sha1() { shasum -a 1 | cut -c1-8; }
else
  sha1() { sha1sum | cut -c1-8; }
fi

mkdir -p "$LOG_DIR" "$STATE_DIR" "$WORK_DIR"

# Fail-state from a previous run would otherwise immediately escalate any
# still-red PR on the first watch pass of this run (same signature wins).
rm -f "$WORK_DIR"/.fail-state.*

ts="$(date +%Y%m%d-%H%M%S)"
inputs_id="$(printf '%s' "$(readlink -f "$INPUTS" 2>/dev/null || echo "$INPUTS")" | sha1)"
runlog="$LOG_DIR/${ts}-${inputs_id}.log"
state_file="$STATE_DIR/${inputs_id}.json"
exec > >(tee -a "$runlog") 2>&1

# log writes to stderr so that lines emitted inside $(plan_then_review …)
# command substitutions still reach the runlog (via the script-level
# `exec 2>&1` to tee) instead of being captured into the variable.
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
log "=== protocol-release-loop ==="
log "Inputs:    $INPUTS"
log "Contract:  $CONTRACT"
log "Lessons:   $LESSONS"
log "Planner:   claude / $CLAUDE_MODEL"
log "Reviewer:  copilot / $REVIEWER_MODEL"
log "State:     $state_file"
log "Workdir:   $WORK_DIR"
log "Run log:   $runlog"
log ""
log "To watch live LLM output in another terminal:"
log "  tail -F $LOG_DIR/${ts}-*"
log "To watch just the runlog (high-level progress):"
log "  tail -f $runlog"

# --- Parse targets from inputs ---
# Pull bullet-list lines under the `## Targets` heading (also accepts the
# legacy `## Repos` heading for inputs files that pre-date the rename).
# Uses while-read instead of mapfile to stay compatible with macOS bash 3.2.
TARGETS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && TARGETS+=("$line")
done < <(
  awk '
    /^##[[:space:]]+(Targets|Repos)/ {in_block=1; next}
    in_block && /^##[[:space:]]/ {in_block=0}
    in_block && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "")
      print
    }
  ' "$INPUTS"
)
[[ "${#TARGETS[@]}" -gt 0 ]] || { echo "ERROR: no targets found (need '## Targets' block in $INPUTS)" >&2; exit 1; }

log "Targets (${#TARGETS[@]}):"
for r in "${TARGETS[@]}"; do log "  - $r"; done

# The "in scope" set starts as Targets and grows whenever claude opens a
# PR against an upstream during Phase 2.
SCOPE=("${TARGETS[@]}")

# --- State helpers (file is a JSON object mapping repo-path → PR URL or "ESCALATED") ---
[[ -f "$state_file" ]] || echo '{}' > "$state_file"

state_get() {  # state_get <repo-path>
  jq -r --arg k "$1" '.[$k] // empty' "$state_file"
}
state_set() {  # state_set <repo-path> <value>
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# --- LLM helpers ---
# Each call streams the model's output to a per-call file under $LOG_DIR so
# the operator can `tail -f` to watch live. The script-level `exec 2>&1` to
# tee logs the file path to the main runlog the moment the call starts.
ask_claude() {
  local f="$LOG_DIR/${ts}-claude-$(date +%H%M%S)-$RANDOM.txt"
  log "  → claude ($CLAUDE_MODEL) streaming. Watch: tail -f $f"
  claude --model "$CLAUDE_MODEL" -p "$1" | tee "$f"
}
ask_copilot_gpt() {
  local f="$LOG_DIR/${ts}-copilot-$(date +%H%M%S)-$RANDOM.txt"
  log "  → copilot streaming. Watch: tail -f $f"
  copilot --model "$REVIEWER_MODEL" --allow-all-tools --allow-all-paths -p "$1" \
    | tee "$f"
}

# Format the "open PRs + statuses" context block that every plan-review
# call receives, so any planner has visibility into the full run.
open_prs_context() {
  local repo url status
  for repo in "${SCOPE[@]}"; do
    url="$(state_get "$repo")"
    if [[ -z "$url" || "$url" == "ESCALATED" ]]; then
      printf -- '- %s: %s\n' "$repo" "${url:-NOT-YET-OPENED}"
      continue
    fi
    status="$(gh pr view "$url" --json statusCheckRollup \
      --jq '[.statusCheckRollup[]? | .conclusion // .status] | unique | tostring' 2>/dev/null \
      || echo '[?]')"
    printf -- '- %s: %s status=%s\n' "$repo" "$url" "$status"
  done
}

# Returns 0 if a repo path is already in $SCOPE, 1 otherwise.
in_scope() {
  local needle="$1" r
  for r in "${SCOPE[@]}"; do [[ "$r" == "$needle" ]] && return 0; done
  return 1
}

# A short paragraph for claude prompts: where each in-scope repo lives,
# and where to clone any upstream repo that needs a fresh PR.
checkouts_block() {
  printf 'Local checkouts in scope (path → PR if opened):\n'
  local r url
  for r in "${SCOPE[@]}"; do
    url="$(state_get "$r")"
    printf '  - %s → %s\n' "$r" "${url:-NOT-YET-OPENED}"
  done
  printf '\n'
  printf 'For any upstream repo not in the list above: git clone it into\n'
  printf '%s/<owner>--<name>/ and open a draft PR from there. Any new PR URL\n' "$WORK_DIR"
  printf 'in your output will be harvested by the script and added to scope.\n'
}

# Extract PR URLs from arbitrary text. Used to harvest "I opened PR X for
# upstream Y" output from claude's execute step so the watch loop adds it
# to scope automatically.
extract_pr_urls() {
  printf '%s' "$1" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | sort -u
}

# Look up the local checkout path for a given PR URL by checking each
# in-scope repo's remote. If none match, return a path under $WORK_DIR
# (the caller is expected to `git clone` there). No filesystem scanning
# outside $WORK_DIR — keeps the script portable.
find_or_propose_repo_for_pr() {
  local pr="$1"
  local nwo r remote
  nwo="$(printf '%s' "$pr" | sed -E 's|https://github\.com/([^/]+/[^/]+)/pull/.*|\1|')"
  for r in "${SCOPE[@]}"; do
    remote="$(cd "$r" 2>/dev/null && git config --get remote.origin.url 2>/dev/null || true)"
    if printf '%s' "$remote" | grep -qiE "[/:]${nwo}(\.git)?\$"; then
      printf '%s' "$r"; return 0
    fi
  done
  # Not found in scope. Propose a workdir path; the caller clones there.
  printf '%s' "$WORK_DIR/${nwo//\//--}"
  return 0
}

# Up to 2 plan-review rounds. Returns the final plan text on stdout.
# task: free-form task description for this round.
# cwd:  repo to cd into for context (the planner usually wants to read
#       one repo's state, even if the eventual fix targets a different repo).
plan_then_review() {
  local task="$1" cwd="$2"
  local plan review
  log "PLAN (claude) — $task"
  plan="$(cd "$cwd" && ask_claude "Task: $task

Working repo:   $(pwd)
Inputs file:    $INPUTS
Contract:       $CONTRACT
Lessons:        $LESSONS

Remember that your end goal is to adapt to any new protocol changes specified.

Open PRs in this run (you may need to fix any of them):
$(open_prs_context)

Repo paths available:
$(checkouts_block)

Read the contract, the lessons file, and the inputs. The lessons file
captures per-repo traps from previous protocol bumps (truncated SHAs,
default-branch quirks, regen post-processing, etc.) — apply it actively,
not just as background.

OPERATING MODE:

- **Upstream-as-part-of-this-run.** If completing this work requires
  changes in an upstream repo, the plan MUST include opening a draft
  PR for that upstream as part of this run — do NOT defer it to the
  operator. Clone the upstream into $WORK_DIR/<owner>--<name>/ if it
  isn't already locally checked out. Sequence the work: upstream PR
  first, then re-pin downstreams to its head SHA.

- **Best effort.** If a piece of work is blocked on something genuinely
  unavailable (e.g. a tool, image, or upstream artifact that doesn't
  exist yet), do the parts that ARE possible and call out what's
  deferred in the PR description. Do NOT refuse to open the PR or
  produce a 'nothing-to-do' plan. Partial progress > deferred work.

Produce a concrete plan — file edits, regen steps, commit message,
target repo(s), target branch. Identify EVERY PR that needs to be
opened or modified, including upstream ones. Do NOT execute. The plan
should be implementable by a separate pass.")"

  local i
  for i in $(seq 1 "$MAX_REVIEW_ROUNDS"); do
    log "REVIEW (copilot/$REVIEWER_MODEL) round $i"
    review="$(ask_copilot_gpt "Independent review for a Stellar protocol-release
bump.
Contract: $CONTRACT
Lessons:  $LESSONS
Inputs:   $INPUTS

Open PRs in this run:
$(open_prs_context)

Read the contract AND the lessons file before reviewing — the lessons
file contains per-repo traps (truncated SHAs, branch defaults, regen
post-processing, etc.) that you should actively check the plan against.

The script's operating mode is **best-effort, upstream-included**:
- The plan SHOULD open upstream PRs in this same run, not defer them.
- The plan SHOULD do as much as possible even when some piece is
  blocked on unavailable artifacts — partial progress > deferred work.

VERDICT FORMAT (machine-parsed): the LAST non-empty line of your reply
must be either the single word "LGTM" (no concerns) or "CONCERNS"
(followed by the concern list above it). The script greps the tail of
your output for the verdict word — don't bury it in prose.

Specifically check:
  - The plan targets the right repo(s) (downstream issues often need
    an upstream fix opened in THIS run).
  - The plan is NOT deferring upstream work or refusing to act on
    blockers — if it is, flag that as the top concern.
  - Pins outside the in-scope set aren't being touched.
  - The regen drops/keeps the correct CAP feature flags.
  - Each trap relevant to the in-scope repos (from the lessons file)
    is either handled or explicitly N/A for this release.

PLAN:
$plan")"

    # Verdict detection: tool-using reviewer models (copilot agent mode)
    # narrate their work before the verdict. Look at the LAST few non-empty
    # lines and accept LGTM there. Also accept LGTM appearing as its own line
    # anywhere in the response.
    if printf '%s' "$review" | grep -qiE '^[[:space:]]*LGTM[[:space:]]*$' \
       || printf '%s' "$review" | tail -n 5 | grep -qiE '\bLGTM\b'; then
      log "  reviewer LGTM on round $i"
      printf '%s' "$plan"
      return
    fi

    log "  reviewer raised concerns; revising plan"
    plan="$(cd "$cwd" && ask_claude "Revise the plan based on this review.
Output only the revised plan.

PREVIOUS PLAN:
$plan

REVIEW:
$review")"
  done

  log "  reached round cap ($MAX_REVIEW_ROUNDS) without LGTM — proceeding with last plan"
  printf '%s' "$plan"
}

# Pull the first failing job's signal lines for a PR. Empty string if none.
failure_signal() {
  local pr="$1"
  local failing_jobs fail_job_url nwo job_id log_excerpt

  # First: enumerate ALL failing jobs by name + URL so the planner can
  # judge whether they're real CI failures or non-blocking tracker
  # workflows (update-completed-on-issue-closed, move-to-done, etc).
  # Apply $IGNORED_CHECKS so the planner never sees checks that are
  # expected to fail on protocol-next (dep-sanity-checker, etc.).
  failing_jobs="$(gh pr view "$pr" --json statusCheckRollup --jq \
    --argjson ignored "$IGNORED_CHECKS_JSON" \
    '[.statusCheckRollup[]?
      | select(.conclusion == "FAILURE")
      | select(((.name // .context // "") | tostring) as $n | ($ignored // []) | index($n) | not)
      | "  - \((.name // .context)): \(.detailsUrl // "")"][:8] | join("\n")' 2>/dev/null)"

  if [[ -n "$failing_jobs" ]]; then
    printf 'Failing jobs on this PR (judge whether any are non-blocking tracker workflows):\n%s\n' "$failing_jobs"
  fi

  # Then: try to pull a log excerpt from the first failing job for context.
  # Same ignore-filter so we don't pull logs from an expected-failing check.
  fail_job_url="$(gh pr view "$pr" --json statusCheckRollup --jq \
    --argjson ignored "$IGNORED_CHECKS_JSON" \
    '[.statusCheckRollup[]?
      | select(.conclusion == "FAILURE")
      | select(((.name // .context // "") | tostring) as $n | ($ignored // []) | index($n) | not)
      | .detailsUrl][0] // empty' 2>/dev/null)"
  if [[ -n "$fail_job_url" ]]; then
    job_id="$(echo "$fail_job_url" | grep -oE '/job/[0-9]+' | grep -oE '[0-9]+')"
    nwo="$(echo "$fail_job_url" | grep -oE 'github.com/[^/]+/[^/]+' | cut -d/ -f2-3)"
    if [[ -n "$job_id" && -n "$nwo" ]]; then
      # Pull the failing-job log with 5 lines BEFORE and 10 lines AFTER each
      # matching diagnostic line. Gives the planner enough context to trace
      # cause→effect (e.g., the command that produced an exit-1 line is
      # usually a few lines above the error itself).
      log_excerpt="$(gh run view --job "$job_id" --log -R "$nwo" 2>/dev/null \
        | grep -B 5 -A 10 -E 'FAIL|--- FAIL|error:|Error:|panic:|maximum decoding depth|timed out|##\[error\]|exit status [1-9]|Process completed with exit code' \
        | head -200 || true)"
      if [[ -n "$log_excerpt" ]]; then
        printf '\nFirst failing job log excerpt (with surrounding context):\n%s\n' "$log_excerpt"
      else
        printf '\n(no diagnostic lines matched; if every failing job above is a tracker workflow, emit SKIP.)\n'
      fi
    fi
  fi
}

# Normalize one statusCheckRollup node to a single string state.
# - CheckRun:      conclusion (e.g. SUCCESS/FAILURE/...) when COMPLETED;
#                  empty string "" + status="IN_PROGRESS"/"QUEUED" while running.
# - StatusContext: state (PENDING/SUCCESS/FAILURE/ERROR/EXPECTED).
# Returns one of: SUCCESS, FAILURE, NEUTRAL, SKIPPED, CANCELLED, TIMED_OUT,
# PENDING, QUEUED, IN_PROGRESS, ERROR, EXPECTED, or UNKNOWN.
#
# Honors $ignored (jq arg, JSON array of check names) — checks whose name or
# context matches an entry in $ignored are dropped from the result entirely.
# This lets the watch loop treat legitimately-failing protocol-next checks
# (e.g. dependency-sanity-checker) as if they weren't there.
_check_state_jq='
  [.statusCheckRollup[]?
    | select(((.name // .context // "") | tostring) as $n | ($ignored // []) | index($n) | not)
    | if (.conclusion // "") != "" then .conclusion
      elif (.status // "") != "" and .status != "COMPLETED" then .status
      elif (.state // "") != "" then .state
      else "UNKNOWN" end]'

# Returns 0 if every check on the PR is SUCCESS/NEUTRAL/SKIPPED.
# (Empty rollup → not green, treated as still-loading.)
pr_is_green() {
  local pr="$1"
  gh pr view "$pr" --json statusCheckRollup --jq \
    --argjson ignored "$IGNORED_CHECKS_JSON" \
    "$_check_state_jq"' | (length > 0) and all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")' \
    2>/dev/null | grep -q '^true$'
}

# Returns 0 if ANY check is still running / queued / awaiting.
pr_is_pending() {
  local pr="$1"
  gh pr view "$pr" --json statusCheckRollup --jq \
    --argjson ignored "$IGNORED_CHECKS_JSON" \
    "$_check_state_jq"' | any(. == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "EXPECTED" or . == "UNKNOWN")' \
    2>/dev/null | grep -q '^true$'
}

# Open a draft PR for a repo: plan_then_review + claude executes. Records
# the resulting PR URL (or ESCALATED) in state. Adds the repo to SCOPE if
# it wasn't already.
open_pr_for_repo() {
  local repo="$1"
  local existing plan pr_url
  existing="$(state_get "$repo")"
  if [[ -n "$existing" && "$existing" != "ESCALATED" ]]; then
    log "Skipping $(basename "$repo") — already open at $existing"
    in_scope "$repo" || SCOPE+=("$repo")
    return 0
  fi

  in_scope "$repo" || SCOPE+=("$repo")
  log "---"
  log "OPEN: $repo"
  plan="$(plan_then_review "Bump this repo for the protocol release per the contract" "$repo")"

  log "EXECUTE (claude): apply plan, commit, push, open draft PR for $(basename "$repo")"
  exec_out="$(cd "$repo" && ask_claude "Apply the plan in full.

The plan may name multiple repos (this one PLUS upstream repos). For
EACH repo named in the plan:
  1. If it's $repo (the current working repo): make the edits here,
     commit on a release-named branch, push, open a DRAFT PR titled
     per the contract.
  2. If it's an upstream repo NOT already locally checked out: git
     clone it into $WORK_DIR/<owner>--<name>/, do the work there,
     commit on the same release-named branch, push to a fork you
     control, and open a DRAFT PR.
  3. Cross-link every PR you open to the others in this run.

OPERATING MODE (do not deviate):

- Open every PR the plan calls for in THIS run. Do not defer upstream
  work to the operator. Do not respond with 'this PR is blocked on
  upstream; please open the upstream PR yourself' — open it.
- Best effort: if a step is genuinely blocked on an unavailable
  artifact (missing tool, no published image, etc.), do the parts that
  ARE possible, open the PR with what you have, and document what's
  deferred in the PR description. A partial PR is the desired outcome.
- Build AND run the relevant tests locally before pushing (best effort —
  if the local toolchain can't build, push and rely on CI, and say so in
  the PR). For stellar-core, configure with
  \`--enable-next-protocol-version-unsafe-for-production\` first.
- Re-recording stellar-core's \`test-tx-meta-baseline-*\` to make CI pass
  is fine (expected when the CAP changes tx semantics or adds tests).
  Inspect the diff; if a tx changed that you did NOT expect, note it in the
  PR for the reviewer — but still commit and continue, don't block.

PR DESCRIPTION STYLE: keep it short — ideally under 15 lines. Bulleted
'## Changes' (what landed) + '## Deferred' (what's not in this PR and
why, one line each) + 'Upstream' / 'Downstream' cross-links. No
narrative analysis, no inline diffs, no restatement of the plan.

Open PRs in this run:
$(open_prs_context)

OUTPUT FORMAT (strict): At the end of your reply, on separate lines,
print every PR URL you opened or pushed to. The script harvests these.
The FIRST URL must be the PR for $repo (i.e., the working repo).

PLAN:
$plan")"
  pr_url="$(printf '%s' "$exec_out" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | head -1)"

  if [[ "$pr_url" =~ ^https://github\.com/.+/pull/[0-9]+$ ]]; then
    state_set "$repo" "$pr_url"
    log "Opened (this repo): $pr_url"
  else
    log "WARNING: $(basename "$repo") execute step did not return a PR URL (got: $pr_url)"
    log "         marking ESCALATED — operator must inspect"
    state_set "$repo" "ESCALATED"
  fi

  # Harvest any ADDITIONAL PR URLs (upstream PRs claude opened in the
  # same execute call). Add each to state + scope so the watch phase
  # tracks them too.
  while IFS= read -r extra_url; do
    [[ -z "$extra_url" ]] && continue
    [[ "$extra_url" == "$pr_url" ]] && continue
    if jq -e --arg v "$extra_url" 'to_entries[] | select(.value == $v)' "$state_file" >/dev/null 2>&1; then
      continue
    fi
    extra_path="$(find_or_propose_repo_for_pr "$extra_url")"
    log "  +upstream PR: $extra_url → $extra_path"
    state_set "$extra_path" "$extra_url"
    in_scope "$extra_path" || SCOPE+=("$extra_path")
  done < <(extract_pr_urls "$exec_out")
}

# =============================================================
# Phase 1: OPEN — walk targets in dep order, open one PR per target
# =============================================================
log ""
log "=== Phase 1: OPEN ==="
for repo in "${TARGETS[@]}"; do
  open_pr_for_repo "$repo"
done

# =============================================================
# Phase 2: WATCH — poll all open PRs; route fixes via planner
# =============================================================
log ""
log "=== Phase 2: WATCH ==="

# Per-repo failure tracking. Bash 3.2 lacks associative arrays, so we
# stash this state under $WORK_DIR/.fail-sig.<sanitized-repo>.
fail_state_file() {
  printf '%s/.fail-state.%s' "$WORK_DIR" "$(printf '%s' "$1" | tr '/' '_')"
}
get_prev_fail_sig() { local f; f="$(fail_state_file "$1").sig"; [[ -f "$f" ]] && cat "$f" || true; }
set_prev_fail_sig() { printf '%s' "$2" > "$(fail_state_file "$1").sig"; }
get_same_fail_count() { local f; f="$(fail_state_file "$1").count"; [[ -f "$f" ]] && cat "$f" || echo 0; }
set_same_fail_count() { printf '%s' "$2" > "$(fail_state_file "$1").count"; }

# Sticky-skip cache: once a PR's failure signature has been verdicted SKIP,
# subsequent watch iterations that see the same signature short-circuit
# without re-running plan-review (and don't trip the same-failure-twice
# escalation either). When the signature changes (new commit, new failure),
# the cache miss and the loop re-evaluates.
get_skip_sig() { local f; f="$(fail_state_file "$1").skipsig"; [[ -f "$f" ]] && cat "$f" || true; }
set_skip_sig() { printf '%s' "$2" > "$(fail_state_file "$1").skipsig"; }
clear_skip_sig() { rm -f "$(fail_state_file "$1").skipsig"; }

# Track the PR state (OPEN / MERGED / CLOSED) per repo so we can detect
# an OPEN→MERGED transition and trigger downstream repins.
get_pr_prev_state() { local f; f="$(fail_state_file "$1").prstate"; [[ -f "$f" ]] && cat "$f" || true; }
set_pr_prev_state() { printf '%s' "$2" > "$(fail_state_file "$1").prstate"; }

# Read the live PR state (OPEN / MERGED / CLOSED) for a URL.
pr_state() {
  gh pr view "$1" --json state --jq .state 2>/dev/null || true
}

# Inside the watch phase we want resilience over strictness: a transient
# `gh` failure, an unexpected jq output, a grep with no match, etc. must
# NOT exit the script — the only exit condition is "all PRs green" or
# MAX_WATCH_ITERS. Relax errexit/pipefail for the duration of the loop;
# the loop body manages its own control flow with explicit `continue`s.
set +e
set +o pipefail

for iter in $(seq 1 "$MAX_WATCH_ITERS"); do
  log ""
  log "--- watch iter $iter/$MAX_WATCH_ITERS ---"

  # Pre-pass: detect OPEN→MERGED transitions among in-scope PRs. Any merge
  # invalidates SKIP caches for the *other* repos (their planners will now
  # see the merge in open_prs_context and can propose a repin to the merge
  # commit). Also stamp the new state so a transition only fires once.
  merged_this_iter=()
  for repo in "${SCOPE[@]}"; do
    pr="$(state_get "$repo")"
    [[ -z "$pr" || "$pr" == "ESCALATED" ]] && continue
    cur_state="$(pr_state "$pr")"
    [[ -z "$cur_state" ]] && continue
    prev_state="$(get_pr_prev_state "$repo")"
    if [[ "$cur_state" == "MERGED" && "$prev_state" != "MERGED" ]]; then
      log "🎉 $(basename "$repo") upstream merged: $pr"
      merged_this_iter+=("$repo")
    fi
    set_pr_prev_state "$repo" "$cur_state"
  done
  if [[ ${#merged_this_iter[@]} -gt 0 ]]; then
    for repo in "${SCOPE[@]}"; do
      # Clear skip cache for OTHER repos so they re-evaluate against the
      # newly-merged upstream and the planner can propose a repin.
      skip_owner=false
      for m in "${merged_this_iter[@]}"; do
        [[ "$m" == "$repo" ]] && skip_owner=true
      done
      [[ "$skip_owner" == true ]] && continue
      if [[ -n "$(get_skip_sig "$repo")" ]]; then
        log "  clearing SKIP cache for $(basename "$repo") — upstream merge may unblock"
        clear_skip_sig "$repo"
        set_same_fail_count "$repo" 0
      fi
    done
  fi

  all_done=true
  any_actionable=false

  for repo in "${SCOPE[@]}"; do
    pr="$(state_get "$repo")"
    [[ -z "$pr" || "$pr" == "ESCALATED" ]] && continue

    if pr_is_green "$pr"; then
      log "$(basename "$repo"): GREEN $pr"
      continue
    fi
    if pr_is_pending "$pr"; then
      log "$(basename "$repo"): pending $pr"
      all_done=false
      continue
    fi

    # Red.
    all_done=false
    log "$(basename "$repo"): RED $pr"

    fail_log="$(failure_signal "$pr")"
    [[ -z "$fail_log" ]] && fail_log="(no failure signal extracted — inspect $pr manually)"
    fail_sig="$(printf '%s' "$fail_log" | head -3)"

    # Sticky-SKIP short-circuit: if this PR was previously verdicted SKIP
    # and the failure signature hasn't changed, don't burn another
    # plan-review cycle. The PR is in a known-non-blocking state.
    skip_sig="$(get_skip_sig "$repo")"
    if [[ -n "$skip_sig" && "$skip_sig" == "$fail_sig" ]]; then
      log "  $(basename "$repo"): SKIP (cached — same fail-sig as previous SKIP verdict)"
      continue
    fi

    any_actionable=true
    log "  signal:"
    printf '    %s\n' "$fail_log" | head -10

    # Same-failure-N detection per-PR. ESCALATE only after the same
    # signature has persisted MAX_SAME_FAIL_RETRIES retries in a row
    # (default 3 — gives the planner a few attempts to diagnose hard
    # CI failures). (Skipped when the SKIP cache would have matched.)
    prev_sig="$(get_prev_fail_sig "$repo")"
    if [[ "$prev_sig" == "$fail_sig" && -n "$fail_sig" ]]; then
      new_count=$(($(get_same_fail_count "$repo") + 1))
      set_same_fail_count "$repo" "$new_count"
      log "  same failure as previous iter ($(basename "$repo")), retry $new_count/$MAX_SAME_FAIL_RETRIES"
      if [[ "$new_count" -ge "$MAX_SAME_FAIL_RETRIES" ]]; then
        log "  ESCALATE: same failure on $(basename "$repo") for $((new_count + 1)) consecutive iters"
        state_set "$repo" "ESCALATED"
        continue
      fi
    else
      set_same_fail_count "$repo" 0
    fi
    set_prev_fail_sig "$repo" "$fail_sig"

    # Plan a fix. INVESTIGATE-aware: the planner can take extra reading
    # turns before committing to FIX/SKIP. Cap at MAX_INVESTIGATE_ROUNDS.
    fix_task="CI is red on $pr ($(basename "$repo")).

Failing-job log excerpt (with surrounding context):
$fail_log

The fix may belong here OR in an UPSTREAM PR in this run. If upstream,
name the upstream repo + PR URL in your plan.

VERDICT FORMAT (machine-parsed): the FIRST non-empty line of your reply
must be one of:
  - SKIP         — failure is non-blocking (tracker workflow, fork-secrets
                   issue, etc.), the fix is waiting on a different upstream
                   that isn't yet green, OR it needs a stellar-core deb/image
                   not published yet — check the apt pool + unsafe-stellar-core
                   docker repo for an artifact whose commit matches the core
                   PR HEAD (see lessons.md), SKIP and re-check next pass until
                   it appears. Add the reasoning below.
  - FIX          — there's actionable work to do. Plan the edits below.
  - INVESTIGATE  — you need another reading pass to be confident in a
                   SKIP/FIX. Write up what you've checked and what's
                   still unknown; the script will re-invoke you with
                   the partial findings as context.
The script greps line 1 for the verdict — put it there."

    fix_plan="$(plan_then_review "$fix_task" "$repo")"

    # INVESTIGATE loop: re-invoke with accumulated findings up to a cap.
    investigate_n=0
    while [[ "$investigate_n" -lt "$MAX_INVESTIGATE_ROUNDS" ]]; do
      inv_line="$(printf '%s' "$fix_plan" | awk 'NF{print; exit}')"
      if ! printf '%s' "$inv_line" | grep -qiE '^\**INVESTIGATE\b'; then
        break
      fi
      investigate_n=$((investigate_n + 1))
      log "  planner: INVESTIGATE (round $investigate_n/$MAX_INVESTIGATE_ROUNDS) — re-invoking"
      fix_plan="$(plan_then_review "$fix_task

PRIOR INVESTIGATION (from previous pass — extend your reading and
either commit to SKIP/FIX or INVESTIGATE again with new findings):
$fix_plan" "$repo")"
    done

    # Final verdict detection: SKIP / FIX (default).
    first_line="$(printf '%s' "$fix_plan" | awk 'NF{print; exit}')"
    if printf '%s' "$first_line" | grep -qiE '^\**SKIP\b' \
       || printf '%s' "$fix_plan" | grep -qiE '^[[:space:]]*##.*Verdict.*\bSKIP\b'; then
      log "  planner: SKIP this round (verdict: $(printf '%s' "$first_line" | head -c 100))"
      # Cache the SKIP'd signature so future iterations short-circuit until
      # the signature changes (new commit, new failure).
      set_skip_sig "$repo" "$fail_sig"
      # Also reset same-failure tracking so the next non-SKIP failure
      # (if any) gets a fresh count.
      set_same_fail_count "$repo" 0
      continue
    fi
    if printf '%s' "$first_line" | grep -qiE '^\**INVESTIGATE\b'; then
      log "  planner: still INVESTIGATE after $MAX_INVESTIGATE_ROUNDS rounds — treating as no-action this iter; will retry next iter"
      continue
    fi
    # Not a SKIP / INVESTIGATE — going to fix something. Clear stale SKIP cache.
    clear_skip_sig "$repo"

    log "  EXECUTE (claude): apply fix"
    fix_out="$(cd "$repo" && ask_claude "Apply this fix. The plan names a
target repo. If the target is one of the in-scope checkouts, cd there
and push to its existing PR branch (do NOT open a new PR for it).

Build and run the relevant tests locally before pushing (best effort — fall
back to push + CI if the local toolchain can't build). For stellar-core,
configure with \`--enable-next-protocol-version-unsafe-for-production\` first.

Re-recording stellar-core's \`test-tx-meta-baseline-*\` to make CI pass is
fine (expected when the CAP changes tx semantics or adds tests). Inspect the
diff; if a tx changed that you did NOT expect, note it in the PR for the
reviewer — but still commit and continue, don't block.

If the target is an UPSTREAM repo that does NOT yet have a PR in this
run, clone it into $WORK_DIR/<owner>--<name>/, create a release-named
branch, push, and open a draft PR. Cross-link the open PRs in the
description.

PR DESCRIPTION STYLE (for any NEW PR you open here): keep it short,
under 15 lines. '## Changes' / '## Deferred' bullets + upstream /
downstream cross-links. No narrative analysis or inline diffs.

Output every PR URL you touched or opened, one per line, on the last
lines of your reply.

$(checkouts_block)

Open PRs in this run:
$(open_prs_context)

PLAN:
$fix_plan")"

    # Harvest any newly-opened upstream PR URLs.
    while IFS= read -r new_url; do
      [[ -z "$new_url" ]] && continue
      # Skip URLs we already track.
      if jq -e --arg v "$new_url" 'to_entries[] | select(.value == $v)' "$state_file" >/dev/null; then
        continue
      fi
      # Locate (or designate a workdir path for) this PR's repo.
      new_path="$(find_or_propose_repo_for_pr "$new_url")"
      if [[ -d "$new_path/.git" ]]; then
        log "  scope+: $new_url → $new_path (existing checkout)"
      else
        log "  scope+: $new_url → $new_path (claude is expected to have cloned here)"
      fi
      state_set "$new_path" "$new_url"
      in_scope "$new_path" || SCOPE+=("$new_path")
    done < <(extract_pr_urls "$fix_out")
  done

  # Done conditions.
  if "$all_done"; then
    log ""
    log "=== ALL DONE ==="
    log "Final state:"
    jq -r 'to_entries[] | "  \(.key): \(.value)"' "$state_file"
    # Exit non-zero if any escalated; zero if all green.
    if jq -e 'to_entries[] | select(.value == "ESCALATED")' "$state_file" >/dev/null; then
      exit 2
    fi
    exit 0
  fi

  if ! "$any_actionable"; then
    log "all not-green PRs are still pending; sleeping ${WATCH_INTERVAL}s"
  fi

  sleep "$WATCH_INTERVAL"
done

log ""
log "ESCALATE: MAX_WATCH_ITERS=$MAX_WATCH_ITERS exhausted; not all PRs green"
log "Final state:"
jq -r 'to_entries[] | "  \(.key): \(.value)"' "$state_file"
exit 2
