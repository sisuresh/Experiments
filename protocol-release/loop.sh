#!/usr/bin/env bash
# protocol-release-loop.sh — drive a Stellar protocol-release PR stack
# end-to-end using two models: claude plans/executes, copilot+gpt reviews.
#
# Single invocation processes every in-scope repo:
#   1. OPEN phase  — for each repo in dep order: plan_then_review →
#                    claude opens a draft PR. PR URLs recorded in state.
#   2. WATCH phase — each iteration is two passes:
#                    POLL pass: ONE gh fetch per PR classifies it
#                    (GREEN/PENDING/RED + OPEN/MERGED/CLOSED + failing-check
#                    signature) and rewrites the status table file.
#                    FIX pass: every actionable red PR gets its own fix job
#                    (plan_then_review → execute), up to MAX_PARALLEL_FIXES
#                    concurrently. The planner can route a fix to ANY open
#                    PR, including an upstream — claude `cd`s there and pushes.
#                    Ends when all PRs are green/merged, when nothing is
#                    actionable and nothing is pending (STALLED — operator
#                    must merge / publish artifacts; exit 3 with a manual-steps
#                    summary), or when MAX_WATCH_ITERS is hit.
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
#   MAX_REVIEW_ROUNDS Plan-revise rounds in plan_then_review (default: 1).
#   MAX_INVESTIGATE_ROUNDS  Cap on INVESTIGATE verdicts before forcing a
#                     decision (default: 3).
#   MAX_SAME_FAIL_RETRIES   Same-signature retries before ESCALATE (default: 3).
#   MAX_PARALLEL_FIXES  Concurrent fix jobs in the watch fix pass (default: 3).
#                     Each red PR's plan→review→execute runs as its own
#                     background job. 1 restores the old fully-serial behavior.
#                     RUN_BUILD builds stay serialized machine-wide regardless
#                     (one build at a time — memory pressure).
#   EXIT_ON_STALL     Default 1: exit 3 (with an operator manual-steps summary)
#                     when a pass finds nothing actionable, nothing pending,
#                     and no fresh merges — i.e. the run can no longer make
#                     progress by itself (waiting on human merges / artifact
#                     publishes). Set 0 to keep polling to MAX_WATCH_ITERS.
#   DRY_WATCH         Set 1 to run a single poll pass (no fixes, no LLM calls
#                     in the watch phase), print the status summary, and exit.
#                     Cheap "where does the release stand right now" command.
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
# Per-repo claude reasoning effort. Most repos use DEFAULT_EFFORT; the heavy
# reasoning repos in MAX_EFFORT_REPOS use 'max'. Passed to `claude --effort`,
# which overrides any inherited CLAUDE_EFFORT/settings default.
DEFAULT_EFFORT="${DEFAULT_EFFORT:-high}"
MAX_EFFORT_REPOS="${MAX_EFFORT_REPOS:-rs-soroban-env stellar-core}"
# Effort for the heavy-reasoning repos in MAX_EFFORT_REPOS. Was 'max'; 'xhigh'
# is a large cost cut with modest quality loss on the two hardest repos.
MAX_EFFORT="${MAX_EFFORT:-xhigh}"
REPO_EFFORT="$DEFAULT_EFFORT"   # current repo's effort; reset per repo below
MAX_WATCH_ITERS="${MAX_WATCH_ITERS:-60}"
WATCH_INTERVAL="${WATCH_INTERVAL:-120}"
# Cap on plan-revise rounds inside plan_then_review. Default 1: a single
# copilot review pass (+ at most one revise), then proceed — favors speed.
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-1}"
# Cap on consecutive INVESTIGATE verdicts before forcing a SKIP/FIX
# decision. INVESTIGATE lets the planner take extra turns reading code
# before producing a fix; cap prevents indefinite digging.
MAX_INVESTIGATE_ROUNDS="${MAX_INVESTIGATE_ROUNDS:-3}"
# Number of times the SAME failure signature is allowed to repeat on a
# PR before the script marks it ESCALATED. Was 1 (escalate on 2nd
# occurrence); 3 lets the planner try 3 fixes for the same signature
# before giving up.
MAX_SAME_FAIL_RETRIES="${MAX_SAME_FAIL_RETRIES:-3}"
# Concurrent fix jobs in the watch fix pass. Each red PR's plan→review→execute
# cycle runs as its own background job (subshell); different repos live in
# different checkouts so they don't collide on files. 1 = serial (old behavior).
# RUN_BUILD builds are additionally serialized by a machine-wide lock so
# parallel jobs can't stack a core build on top of cargo builds and OOM the box.
MAX_PARALLEL_FIXES="${MAX_PARALLEL_FIXES:-3}"
# IGNORED_CHECKS is NOT a list of "expected to fail" checks — deciding whether
# a failure is expected is now the planner's job (see the watch-loop verdict
# prompt: for EVERY failing check it judges "should this be green at this point
# in the release, or is it expected to stay red until a later step lands?").
#
# This list is ONLY for derivative checks that carry no independent signal —
# pure aggregators whose failure is fully explained by another check:
#   - complete: the rollup workflow that just ANDs the required checks; it
#     fails as a mechanical consequence of any input failing, so surfacing it
#     is noise, not information. The planner judges the underlying checks.
# Everything else — including dependency-sanity-checker and check-git-rev-deps,
# which are usually expected to fail mid-transition but CAN also fail for real
# (missing p{N}-expect.txt, a typo'd rev) — reaches the planner so it can tell
# expected-now from actually-broken. Override via env to widen the fast-path
# for a release where you already know certain checks are non-actionable.
# Build a JSON array form for jq's --argjson.
IGNORED_CHECKS="${IGNORED_CHECKS:-complete}"
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
_gh_ok=false
for _i in 1 2 3; do
  if gh auth status >/dev/null 2>&1; then _gh_ok=true; break; fi
  sleep 3
done
[[ "$_gh_ok" == true ]] || { echo "ERROR: gh not authenticated (after 3 tries)" >&2; exit 1; }

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
# Stale locks / poll table / claude-session markers from a previous (killed) run.
rm -rf "$STATE_DIR"/.lock-* "$WORK_DIR/.poll"
rm -f "$STATE_DIR"/.sess-* 2>/dev/null || true

ts="$(date +%Y%m%d-%H%M%S)"
inputs_id="$(printf '%s' "$(readlink -f "$INPUTS" 2>/dev/null || echo "$INPUTS")" | sha1)"
runlog="$LOG_DIR/${ts}-${inputs_id}.log"
state_file="$STATE_DIR/${inputs_id}.json"
# At-a-glance status table, rewritten every watch poll pass. `cat` (or
# `watch cat`) this instead of scrolling the runlog.
STATUS_FILE="$STATE_DIR/${inputs_id}-status.txt"
# Per-call claude token usage (TSV), one row per ask_claude turn — see ask_claude.
TOKEN_LOG="$LOG_DIR/${ts}-tokens.tsv"
printf 'time\tsession\teffort\tin\tout\tcache_read\tcache_create\tcost_usd\tcallfile\n' > "$TOKEN_LOG"
# Per-iteration poll results, one file per repo: "MSTATE\tSTATUS\tSIG".
POLL_DIR="$WORK_DIR/.poll"
# Cross-PR context cache: rebuilt once per watch iteration from the poll
# table; empty means "not in the watch phase, fetch live" (Phase 1).
OPEN_PRS_CACHE=""
exec > >(tee -a "$runlog") 2>&1

# log writes to stderr so that lines emitted inside $(plan_then_review …)
# command substitutions still reach the runlog (via the script-level
# `exec 2>&1` to tee) instead of being captured into the variable.
log() { printf '[%s] %s%s\n' "$(date '+%H:%M:%S')" "${LOG_PREFIX:-}" "$*" >&2; }

# --- Background-job hygiene ---
# Parallel fix jobs spawn claude/copilot/build subprocesses. If the operator
# kills this script, those must die too — an orphaned claude session kept
# pushing commits after a kill once. kill_tree walks descendants depth-first.
FIX_PIDS=""
kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill "$1" 2>/dev/null || true
}
cleanup_jobs() {
  local p
  for p in $FIX_PIDS; do
    if kill -0 "$p" 2>/dev/null; then
      log "cleanup: killing fix job $p (and its subprocesses)"
      kill_tree "$p"
    fi
  done
}
trap cleanup_jobs EXIT
trap 'exit 130' INT TERM

# --- mkdir spinlocks (macOS has no flock; mkdir is atomic) ---
# Used for: state-file writes from parallel fix jobs, and the machine-wide
# one-build-at-a-time RUN_BUILD lock. Stale locks are removed at startup.
lock_acquire() {  # lock_acquire <name> [timeout-seconds]  → 0 ok, 1 timed out
  local name="$1" max="${2:-600}" d t=0
  d="$STATE_DIR/.lock-$name"
  until mkdir "$d" 2>/dev/null; do
    [[ "$t" -eq 0 ]] && log "  (waiting for $name lock…)"
    sleep 2; t=$((t+2))
    if [[ "$t" -ge "$max" ]]; then
      log "  WARN: $name lock not acquired after ${max}s — proceeding anyway"
      return 1
    fi
  done
  return 0
}
lock_release() { rmdir "$STATE_DIR/.lock-$1" 2>/dev/null || true; }

log "=== protocol-release-loop ==="
log "Inputs:    $INPUTS"
log "Contract:  $CONTRACT"
log "Lessons:   $LESSONS"
log "Planner:   claude / $CLAUDE_MODEL"
log "Reviewer:  copilot / $REVIEWER_MODEL"
log "State:     $state_file"
log "Workdir:   $WORK_DIR"
log "Run log:   $runlog"
log "Status:    $STATUS_FILE   (rewritten every watch poll pass — 'watch cat' it)"
log "Tokens:    $TOKEN_LOG   (per-call token usage, TSV)"
log "Parallel:  up to $MAX_PARALLEL_FIXES concurrent fix jobs (MAX_PARALLEL_FIXES)"
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
      sub(/[[:space:]]*#.*$/, "")    # strip inline comments
      sub(/[[:space:]]+$/, "")       # strip trailing whitespace
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
  # Locked: parallel fix jobs write concurrently; an unlocked read-modify-write
  # (jq from the same base, two mvs) silently drops the loser's key.
  # Readers need no lock — mv replacement is atomic.
  local tmp
  lock_acquire state 120 || true
  tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  lock_release state
}

# --- LLM helpers ---
# Each call streams the model's output to a per-call file under $LOG_DIR so
# the operator can `tail -f` to watch live. The script-level `exec 2>&1` to
# tee logs the file path to the main runlog the moment the call starts.
# Effort level for a repo: 'max' for MAX_EFFORT_REPOS (matches either the bare
# name or an <owner>--<name> workdir clone), else DEFAULT_EFFORT.
effort_for_repo() {
  local name r; name="$(basename "$1")"
  for r in $MAX_EFFORT_REPOS; do
    [[ "$name" == "$r" || "$name" == *"--$r" ]] && { printf '%s' "$MAX_EFFORT"; return; }
  done
  printf '%s' "$DEFAULT_EFFORT"
}

# A fresh lowercased UUID for a per-repo claude session (see ask_claude).
new_session_id() { uuidgen | tr 'A-Z' 'a-z'; }

# ask_claude runs one non-interactive claude turn. When CLAUDE_SESSION_ID is set
# (open_pr_for_repo / fix_one_repo assign a fresh one per repo), the FIRST call
# in that repo unit CREATES the session (--session-id) and every later call
# RESUMES it (--resume) — so plan → execute → RUN_BUILD re-invokes share one
# conversation instead of each re-reading the docs and re-exploring the repo
# from scratch. First-vs-resume is tracked with an on-disk marker, because every
# ask_claude call runs inside $(command substitution): a shell variable set
# there wouldn't survive to the next call, but a marker file does. Calls within
# one repo unit are sequential, so no locking is needed. Unset id → old behavior.
ask_claude() {
  local f="$LOG_DIR/${ts}-claude-$(date +%H%M%S)-$RANDOM.txt"
  local sflag=() smsg=""
  if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    if [[ -f "$STATE_DIR/.sess-$CLAUDE_SESSION_ID" ]]; then
      sflag=(--resume "$CLAUDE_SESSION_ID"); smsg=" resume ${CLAUDE_SESSION_ID:0:8}"
    else
      sflag=(--session-id "$CLAUDE_SESSION_ID"); smsg=" new-session ${CLAUDE_SESSION_ID:0:8}"
      : > "$STATE_DIR/.sess-$CLAUDE_SESSION_ID"
    fi
  fi
  log "  → claude ($CLAUDE_MODEL, effort=${REPO_EFFORT:-$DEFAULT_EFFORT}${smsg}) — reply to $f on completion"
  # --output-format json so we can record per-call token usage. `.result` is the
  # text callers expect on stdout; `.usage`/`.total_cost_usd` go to $TOKEN_LOG
  # plus a runlog line. If claude emits non-result output (the plain-text spend-
  # limit notice, or an error), fall through and pass it straight on so the
  # caller's existing no-URL / escalate handling still fires. Tradeoff vs. the
  # old text mode: the reply lands in $f on completion, not streamed live.
  # ${sflag[@]+...}: safe empty-array expansion under `set -u` on bash 3.2.
  local raw text row
  raw="$(claude --model "$CLAUDE_MODEL" --effort "${REPO_EFFORT:-$DEFAULT_EFFORT}" ${sflag[@]+"${sflag[@]}"} --output-format json -p "$1")" || true
  if text="$(printf '%s' "$raw" | jq -er '.result' 2>/dev/null)"; then
    printf '%s\n' "$text" > "$f"
    row="$(printf '%s' "$raw" | jq -r \
      --arg t "$(date '+%H:%M:%S')" --arg s "${CLAUDE_SESSION_ID:0:8}" \
      --arg e "${REPO_EFFORT:-$DEFAULT_EFFORT}" --arg fn "$(basename "$f")" \
      '[$t,$s,$e,(.usage.input_tokens//0),(.usage.output_tokens//0),(.usage.cache_read_input_tokens//0),(.usage.cache_creation_input_tokens//0),(.total_cost_usd//0),$fn]|@tsv')"
    printf '%s\n' "$row" >> "$TOKEN_LOG"
    log "    ← tokens $(printf '%s' "$row" | awk -F'\t' '{printf "in=%s out=%s cache_read=%s cost=$%s",$4,$5,$6,$8}')"
    printf '%s' "$text"
  else
    printf '%s' "$raw" | tee "$f"
  fi
}
ask_copilot_gpt() {
  local f="$LOG_DIR/${ts}-copilot-$(date +%H%M%S)-$RANDOM.txt"
  log "  → copilot streaming. Watch: tail -f $f"
  copilot --model "$REVIEWER_MODEL" --allow-all-tools --allow-all-paths -p "$1" \
    | tee "$f"
}

# Format the "open PRs + statuses" context block that every plan-review
# call receives, so any planner has visibility into the full run.
# In the watch phase OPEN_PRS_CACHE (rebuilt once per iteration from the
# poll table) short-circuits this — otherwise EVERY planner/review/execute
# prompt re-fetches every PR (N gh calls per prompt), which is what used to
# trip GitHub's secondary rate limit. Phase 1 has no cache → live fetch.
open_prs_context() {
  if [[ -n "${OPEN_PRS_CACHE:-}" ]]; then
    printf '%s' "$OPEN_PRS_CACHE"
    return
  fi
  local repo url status
  for repo in "${SCOPE[@]}"; do
    url="$(state_get "$repo")"
    if [[ -z "$url" || "$url" == "ESCALATED" ]]; then
      printf -- '- %s: %s\n' "$repo" "${url:-NOT-YET-OPENED}"
      continue
    fi
    # Include the PR's merge state (OPEN/MERGED/CLOSED), not just check status:
    # the planner needs it to judge whether a downstream failure is "expected
    # now, waiting on this still-OPEN upstream" vs "this upstream MERGED, so
    # propose the repin now".
    status="$(gh pr view "$url" --json state,statusCheckRollup \
      --jq '"\(.state) checks=\([.statusCheckRollup[]? | .conclusion // .status] | unique | tostring)"' 2>/dev/null \
      || echo 'UNKNOWN')"
    printf -- '- %s: %s [%s]\n' "$repo" "$url" "$status"
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
    # Match against ALL remotes, not just origin: these checkouts have
    # origin=<fork> while the PR lives on the stellar/* upstream, so an
    # origin-only match mis-mapped every harvested upstream PR to a fresh
    # clones/ path — duplicate state keys for the same PR.
    remote="$(cd "$r" 2>/dev/null && git remote -v 2>/dev/null | awk '{print $2}' | sort -u || true)"
    if printf '%s\n' "$remote" | grep -qiE "[/:]${nwo}(\.git)?\$"; then
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

  # First: enumerate EVERY genuinely-failing check (terminal non-pass state)
  # by name + state + URL, sorted by name, so the planner can judge each one
  # ("should this be green now, or expected to stay red until a later step?").
  # $IGNORED_CHECKS drops only derivative aggregators (e.g. `complete`) — the
  # planner sees all real failures, including ones usually expected to fail.
  failing_jobs="$(gh pr view "$pr" --json statusCheckRollup --jq \
    --argjson ignored "$IGNORED_CHECKS_JSON" \
    '[.statusCheckRollup[]?
      | select(((.name // .context // "") | tostring) as $n | ($ignored // []) | index($n) | not)
      | {n: (.name // .context // "?"),
         s: (if (.conclusion // "") != "" then .conclusion
              elif (.status // "") != "" and .status != "COMPLETED" then .status
              elif (.state // "") != "" then .state else "UNKNOWN" end),
         u: (.detailsUrl // "")}
      | select(.s | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","STALE"))]
      | sort_by(.n) | map("  - \(.n) [\(.s)]: \(.u)")[:12] | join("\n")' 2>/dev/null)"

  if [[ -n "$failing_jobs" ]]; then
    printf 'Failing checks on this PR. For EACH, decide: should it be green at this point in the release, or is it expected to stay red until a later step in this run lands?\n%s\n' "$failing_jobs"
  fi

  # Then: pull a log excerpt from the first failing check (sorted by name, same
  # ignore-filter) for context.
  fail_job_url="$(gh pr view "$pr" --json statusCheckRollup --jq \
    --argjson ignored "$IGNORED_CHECKS_JSON" \
    '[.statusCheckRollup[]?
      | select(((.name // .context // "") | tostring) as $n | ($ignored // []) | index($n) | not)
      | {n: (.name // .context // "?"),
         s: (if (.conclusion // "") != "" then .conclusion
              elif (.status // "") != "" and .status != "COMPLETED" then .status
              elif (.state // "") != "" then .state else "UNKNOWN" end),
         u: (.detailsUrl // "")}
      | select(.s | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","STALE"))]
      | sort_by(.n) | (.[0].u) // empty' 2>/dev/null)"
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

# A STABLE signature of a PR's failing checks: sorted "name[state]" with NO
# URLs. detailsUrl embeds run/job IDs that change on every CI re-run, so a
# URL-based signature would bust the SKIP cache on every benign re-run. This
# changes only when the SET of failing checks (or their states) changes —
# which is exactly when the planner should re-evaluate.
failure_sig() {
  gh pr view "$1" --json statusCheckRollup --jq \
    --argjson ignored "$IGNORED_CHECKS_JSON" \
    '[.statusCheckRollup[]?
      | select(((.name // .context // "") | tostring) as $n | ($ignored // []) | index($n) | not)
      | {n: (.name // .context // "?"),
         s: (if (.conclusion // "") != "" then .conclusion
              elif (.status // "") != "" and .status != "COMPLETED" then .status
              elif (.state // "") != "" then .state else "UNKNOWN" end)}
      | select(.s | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","STALE"))
      | "\(.n)[\(.s)]"] | sort | join(",")' 2>/dev/null || true
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

# Poll one PR with a SINGLE gh fetch (retried on transient failure / secondary
# rate limit) and emit everything the watch loop needs, tab-separated:
#   MSTATE  — OPEN / MERGED / CLOSED / UNKNOWN (merge state)
#   STATUS  — GREEN   all (non-ignored) checks SUCCESS/NEUTRAL/SKIPPED
#             PENDING at least one check running/queued (or none reported yet)
#             RED     a real failure, nothing pending
#             UNKNOWN couldn't read CI after retries (treat as pending, NEVER red)
#   SIG     — stable failing-check signature (sorted "name[state]", no URLs;
#             empty unless RED). Same key the SKIP cache uses.
# One fetch (not separate green/pending/state calls) so a gh burst can't break
# one check but not another and misread a green PR as RED — and the whole
# iteration costs N calls instead of ~4N.
poll_pr() {
  local pr="$1" payload="" t mstate states status sig
  for t in 1 2 3; do
    payload="$(gh pr view "$pr" --json state,statusCheckRollup 2>/dev/null)"
    [[ -n "$payload" ]] && break
    sleep 5
  done
  if [[ -z "$payload" ]]; then printf 'UNKNOWN\tUNKNOWN\t\n'; return; fi
  mstate="$(printf '%s' "$payload" | jq -r '.state // "UNKNOWN"' 2>/dev/null)"
  [[ -z "$mstate" ]] && mstate="UNKNOWN"
  states="$(printf '%s' "$payload" | jq -r --argjson ignored "$IGNORED_CHECKS_JSON" "$_check_state_jq | .[]?" 2>/dev/null)"
  if [[ -z "$states" ]]; then
    status="PENDING"
  elif printf '%s\n' "$states" | grep -qE '^(PENDING|QUEUED|IN_PROGRESS|EXPECTED|UNKNOWN)$'; then
    status="PENDING"
  elif printf '%s\n' "$states" | grep -qvE '^(SUCCESS|NEUTRAL|SKIPPED)$'; then
    status="RED"
  else
    status="GREEN"
  fi
  sig=""
  if [[ "$status" == "RED" ]]; then
    sig="$(printf '%s' "$payload" | jq -r --argjson ignored "$IGNORED_CHECKS_JSON" \
      '[.statusCheckRollup[]?
        | select(((.name // .context // "") | tostring) as $n | ($ignored // []) | index($n) | not)
        | {n: (.name // .context // "?"),
           s: (if (.conclusion // "") != "" then .conclusion
                elif (.status // "") != "" and .status != "COMPLETED" then .status
                elif (.state // "") != "" then .state else "UNKNOWN" end)}
        | select(.s | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","STALE"))
        | "\(.n)[\(.s)]"] | sort | join(",")' 2>/dev/null)"
  fi
  printf '%s\t%s\t%s\n' "$mstate" "$status" "$sig"
}

# Per-repo poll-result file for the current iteration.
poll_file() {
  printf '%s/%s' "$POLL_DIR" "$(printf '%s' "$1" | tr '/' '_')"
}

# Open a draft PR for a repo: plan_then_review + claude executes. Records
# the resulting PR URL (or ESCALATED) in state. Adds the repo to SCOPE if
# it wasn't already.
# Service a RUN_BUILD: handoff from an execute step. Claude emits
# `RUN_BUILD: <cmd>` as its last line instead of running a long build itself (a
# -p turn is never re-invoked, so a backgrounded build would strand the run);
# the SCRIPT runs it in $repo — no turn limit — waits (heartbeat every 5 min,
# hard cap MAX_BUILD_WAIT), then re-invokes claude with the exit code + log tail
# plus $reinvoke to finish. Loops if claude requests another build, up to
# MAX_BUILD_CYCLES. Returns via global RUN_BUILD_RESULT (not stdout — the loop
# calls ask_claude repeatedly). If no build was requested, RUN_BUILD_RESULT is
# the input exec_out unchanged. Builds run IN-TREE in $repo, so autotools
# objects + ccache persist across runs and rebuilds are incremental.
run_build_handoff() {
  local repo="$1" exec_out="$2" reinvoke="$3"
  local blog build_cmd build_rc bcycle bp waited
  blog="$(mktemp "${TMPDIR:-/tmp}/prl-build-$(basename "$repo").XXXXXX")"
  bcycle=0
  build_cmd="$(printf '%s' "$exec_out" | sed -n 's/^RUN_BUILD:[[:space:]]*//p' | head -1)"
  while [[ -n "$build_cmd" ]] && [[ "$bcycle" -lt "${MAX_BUILD_CYCLES:-4}" ]]; do
    bcycle=$((bcycle+1))
    log "  ⏳ RUN_BUILD (cycle $bcycle) for $(basename "$repo"): $build_cmd"
    # ONE build at a time machine-wide: parallel fix jobs could otherwise
    # stack a stellar-core compile on top of cargo builds and OOM the box
    # (that hang happened once with an unbounded make -j).
    lock_acquire build $(( ${MAX_BUILD_WAIT:-5400} + 1800 )) || true
    log "     watch: tail -f $blog   (max ${MAX_BUILD_WAIT:-5400}s)"
    ( cd "$repo" && eval "$build_cmd" ) > "$blog" 2>&1 &
    bp=$!; waited=0
    while kill -0 "$bp" 2>/dev/null; do
      sleep 30; waited=$((waited+30))
      if [[ $(( waited % 300 )) -eq 0 ]]; then log "    …building $(basename "$repo") (${waited}s elapsed)"; fi
      if [[ "$waited" -ge "${MAX_BUILD_WAIT:-5400}" ]]; then
        log "    build exceeded ${MAX_BUILD_WAIT:-5400}s — killing pid $bp and continuing"
        kill "$bp" 2>/dev/null || true; break
      fi
    done
    build_rc=0; wait "$bp" 2>/dev/null || build_rc=$?
    lock_release build
    log "  build finished (exit $build_rc) for $(basename "$repo") — re-invoking claude"
    exec_out="$(cd "$repo" && ask_claude "The build the script ran for you finished with exit code $build_rc. Log tail:
$(tail -40 "$blog" 2>/dev/null)

$reinvoke")" || true
    build_cmd="$(printf '%s' "$exec_out" | sed -n 's/^RUN_BUILD:[[:space:]]*//p' | head -1)"
  done
  rm -f "$blog" 2>/dev/null || true
  RUN_BUILD_RESULT="$exec_out"
}

open_pr_for_repo() {
  local repo="$1"
  local existing plan pr_url
  # One claude session for this repo's whole pipeline (plan → execute → builds
  # → finish-up), so later turns reuse the earlier ones' context instead of
  # re-reading the docs and re-exploring the repo. local → dynamic scoping makes
  # it visible to ask_claude/plan_then_review/run_build_handoff called below.
  local CLAUDE_SESSION_ID; CLAUDE_SESSION_ID="$(new_session_id)"
  REPO_EFFORT="$(effort_for_repo "$repo")"
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

SCOPE LIMIT — upstream ONLY: open PRs solely for $repo and for repos
that are UPSTREAM dependencies of it (earlier in the dependency chain).
NEVER open PRs for DOWNSTREAM repos (later targets — SDKs, services,
UIs that consume this repo), even if their work seems obvious or old
release branches for them exist locally: each target gets its own
dedicated plan/review pass later in this run, and pre-opening it with
copied or stale content bypasses that pass. One run opened all 11
downstream PRs from a single turn this way — do not repeat it.

OPERATING MODE (do not deviate):

- START FROM A FRESH BASE: before any edits, fetch the upstream and check out
  this repo's base branch (main/master for the gated layers, protocol-next for
  go-stellar-sdk/horizon/rpc — see lessons.md), fast-forward it to the latest
  upstream, and create the release branch from it. If the release branch already
  exists locally from a prior run, delete and recreate it from the fresh base —
  never build on leftover local state.
- ALWAYS open every PR against the UPSTREAM repo (e.g. \`stellar/<repo>\`) as a
  cross-fork PR: push the branch to your fork, then
  \`gh pr create -R stellar/<repo> --base <base-branch> --head <fork-owner>:<branch>\`.
  NEVER open a fork-internal PR (base on your own fork) and NEVER invent a
  synthetic base branch to get a clean diff (see lessons.md).
- Open every PR the plan calls for in THIS run. Do not defer upstream
  work to the operator. Do not respond with 'this PR is blocked on
  upstream; please open the upstream PR yourself' — open it.
- Best effort: if a step is genuinely blocked on an unavailable
  artifact (missing tool, no published image, etc.), do the parts that
  ARE possible, open the PR with what you have, and document what's
  deferred in the PR description. A partial PR is the desired outcome.
- Builds/tests: if quick (cargo/go, a few minutes), run them synchronously now.
  If a LONG build/test is needed before finalizing (e.g. a full stellar-core
  compile, or a TxMeta re-record that needs a freshly built test binary), do
  NOT run it yourself and do NOT background it — make all source edits first,
  then output a single line \`RUN_BUILD: <shell command runnable from the repo
  root>\` as the LAST line and STOP (do not push or open the PR yet). The script
  runs that build, waits for it however long it takes, and re-invokes you with
  the exit code + log to commit, push, and open the PR. If a command you
  started gets AUTO-BACKGROUNDED by your harness, do NOT end your turn
  waiting for its notification — it never arrives in -p mode; emit the
  RUN_BUILD line for that command instead.
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
$plan")" || true

  # Long-build handoff (see run_build_handoff): the SCRIPT runs any RUN_BUILD:
  # claude requested, waits, and re-invokes to finish.
  run_build_handoff "$repo" "$exec_out" "Now: fix any build fallout, commit ALL changes (including build-generated files) on the release branch, push, and open the draft PR per the contract. If the exit code was non-zero, fix the cause first. The cause may be UPSTREAM, not this repo — if the failure traces to an upstream repo (one earlier in the dep chain, whose PR is already open this run), \`cd\` to that upstream repo, push the fix to its EXISTING PR branch (do NOT open a new PR for it), re-pin THIS repo to the upstream's new head, then request another build. OUTPUT FORMAT: print every PR URL on separate lines at the end (including any upstream PR you pushed to), the FIRST being the PR for $repo. To request ANOTHER build, output a single \`RUN_BUILD: <cmd>\` line as the very last line and stop."
  exec_out="$RUN_BUILD_RESULT"

  # `|| true`: grep exits 1 on no match, and Phase 1 runs under errexit+pipefail
  # — an execute turn with no URL in its output used to kill the whole script
  # SILENTLY right here (first tripped by a turn that ended waiting on an
  # auto-backgrounded `make generate`).
  pr_url="$(printf '%s' "$exec_out" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || true)"

  # Finish-up retry: a turn that ends waiting on a background job (the harness
  # auto-backgrounds long commands; the completion notification NEVER arrives
  # in -p mode) produces no PR URL. Give claude ONE recovery turn — finish
  # synchronously or hand the long command to RUN_BUILD — before escalating.
  if [[ -z "$pr_url" ]]; then
    log "  execute ended without a PR URL — one finish-up re-invoke"
    exec_out="$(cd "$repo" && ask_claude "Your previous execute turn for $repo ended WITHOUT printing any PR URL. Its final message was:
$exec_out

You are in -p mode: any background/monitored job you were waiting on will NEVER notify you — that turn is over. Finish the job NOW:
- If a long build/regen still needs to (re)run, emit a single \`RUN_BUILD: <cmd>\` line as your LAST line and STOP — the script runs it and re-invokes you.
- Otherwise: inspect the working tree, complete the remaining plan steps, commit, push to the release branch, make sure the draft PR exists per the contract, and print every PR URL on separate lines at the end, the FIRST being the PR for $repo.")" || true
    run_build_handoff "$repo" "$exec_out" "Now: fix any build fallout, commit ALL changes (including build-generated files) on the release branch, push, and open the draft PR per the contract. OUTPUT FORMAT: print every PR URL on separate lines at the end, the FIRST being the PR for $repo. To request ANOTHER build, output a single \`RUN_BUILD: <cmd>\` line as the very last line and stop."
    exec_out="$RUN_BUILD_RESULT"
    pr_url="$(printf '%s' "$exec_out" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || true)"
  fi

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
if [[ "${DRY_WATCH:-0}" == "1" ]]; then
  # A status snapshot must not open PRs or invoke planners — repos without
  # an open PR are simply reported as NOT-OPENED in the table below.
  log "DRY_WATCH: skipping Phase 1 (nothing is opened in a dry run)"
else
  for repo in "${TARGETS[@]}"; do
    open_pr_for_repo "$repo"
  done
fi

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

# The one-line reason the planner gave for a SKIP verdict; surfaced in the
# status table and the final operator summary ("waiting on: …").
set_skip_reason() { printf '%s' "$2" > "$(fail_state_file "$1").skipreason"; }
get_skip_reason() { local f; f="$(fail_state_file "$1").skipreason"; [[ -f "$f" ]] && cat "$f" || true; }

# Escalation = "frozen for THIS run, operator should look" — a side flag, NOT
# a state-file value. Writing the literal string ESCALATED into state used to
# OVERWRITE the PR URL, so the next run forgot the PR existed and re-planned
# it from scratch (fresh-base would even clobber the branch). The flag lives
# under .fail-state.* so the startup wipe clears it: a re-run re-judges the
# repo with fresh counters instead of re-opening its PR. (state=ESCALATED is
# still written by Phase 1 when opening FAILED — there's no URL to preserve.)
set_escalated() { : > "$(fail_state_file "$1").escalated"; }
is_escalated()  { [[ -f "$(fail_state_file "$1").escalated" ]]; }
any_escalated() {
  jq -e 'to_entries[] | select(.value == "ESCALATED")' "$state_file" >/dev/null 2>&1 && return 0
  ls "$WORK_DIR"/.fail-state.*.escalated >/dev/null 2>&1
}

# SCOPE = Targets ∪ state-file keys, targets first (dep order), state-only
# entries appended in insertion order. Rebuilt at the top of every watch
# iteration: parallel fix jobs run in subshells, so a `SCOPE+=` there would be
# lost — they record new upstream PRs in the STATE FILE instead, and this
# picks them up.
# DEDUP BY PR URL: two state keys can point at the SAME PR (e.g. a harvested
# clones/ mapping plus the real ~/dev checkout). Watching both would spawn two
# parallel fix jobs on one PR. Keep only the first key per URL — targets
# (~/dev, dep order) come first, so the real checkout always wins.
rebuild_scope() {
  SCOPE=("${TARGETS[@]}")
  local k u seen_urls=""
  for k in "${TARGETS[@]}"; do
    u="$(state_get "$k")"
    [[ -n "$u" && "$u" != "ESCALATED" ]] && seen_urls="$seen_urls $u"
  done
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    in_scope "$k" && continue
    u="$(state_get "$k")"
    if [[ -n "$u" && "$u" != "ESCALATED" ]]; then
      case " $seen_urls " in
        *" $u "*)
          continue ;;   # same PR already watched under an earlier key
      esac
      seen_urls="$seen_urls $u"
    fi
    SCOPE+=("$k")
  done < <(jq -r 'keys_unsorted[]' "$state_file" 2>/dev/null)
}

# Rewrite the at-a-glance status table ($STATUS_FILE) from the current poll
# table. $1 = one-line activity note (what the loop is doing right now).
write_status_file() {
  local note="${1:-}" tmp repo url f mstate status sig disp extra sk
  tmp="$(mktemp)"
  {
    printf '%s — iter %s/%s @ %s\n' "$(basename "$INPUTS")" "${iter:-0}" "$MAX_WATCH_ITERS" "$(date '+%F %T')"
    [[ -n "$note" ]] && printf '>> %s\n' "$note"
    printf '\n'
    for repo in "${SCOPE[@]}"; do
      url="$(state_get "$repo")"
      if [[ -z "$url" ]]; then
        printf '%-13s %-26s\n' "NOT-OPENED" "$(basename "$repo")"
        continue
      fi
      if [[ "$url" == "ESCALATED" ]]; then
        printf '%-13s %-26s %s\n' "ESCALATED" "$(basename "$repo")" "operator must inspect (see runlog)"
        continue
      fi
      f="$(poll_file "$repo")"
      mstate=""; status="?"; sig=""
      [[ -f "$f" ]] && IFS=$'\t' read -r mstate status sig < "$f"
      disp="$status"; extra=""
      if is_escalated "$repo"; then
        disp="ESCALATED"; extra="frozen this run — operator must inspect"
      elif [[ "$mstate" == "MERGED" ]]; then
        disp="MERGED"
      elif [[ "$status" == "RED" ]]; then
        sk="$(get_skip_sig "$repo")"
        if [[ -n "$sk" && "$sk" == "$sig" ]]; then
          disp="EXPECTED-RED"
          extra="waiting: $(get_skip_reason "$repo" | cut -c1-160)"
        else
          extra="failing: $sig"
        fi
      fi
      printf '%-13s %-26s %s%s\n' "$disp" "$(basename "$repo")" "$url" "${extra:+   $extra}"
    done
  } > "$tmp" && mv "$tmp" "$STATUS_FILE"
}

# Final per-repo report + explicit operator TODO. Used by every exit path
# (ALL DONE, STALLED, iters exhausted, DRY_WATCH) so the run always ends by
# saying what a human must do next — never just a state dump.
final_summary() {
  local headline="$1"
  local repo url f mstate status sig reason has_core_open=false
  log ""
  log "=== $headline ==="
  for repo in "${SCOPE[@]}"; do
    url="$(state_get "$repo")"
    if [[ -z "$url" ]]; then
      log "  ⚪ $(basename "$repo"): NOT-OPENED"
      continue
    fi
    if [[ "$url" == "ESCALATED" ]]; then
      log "  🛑 $(basename "$repo"): ESCALATED — operator must inspect (see runlog)"
      continue
    fi
    f="$(poll_file "$repo")"
    mstate=""; status="?"; sig=""
    [[ -f "$f" ]] && IFS=$'\t' read -r mstate status sig < "$f"
    case "$(basename "$repo")" in
      stellar-core|*--stellar-core) [[ "$mstate" != "MERGED" ]] && has_core_open=true ;;
    esac
    if is_escalated "$repo"; then
      log "  🛑 $(basename "$repo"): ESCALATED — frozen this run, operator must inspect  $url"
      continue
    fi
    if [[ "$mstate" == "MERGED" ]]; then
      log "  ✅ $(basename "$repo"): MERGED  $url"
    elif [[ "$status" == "GREEN" ]]; then
      log "  🟢 $(basename "$repo"): GREEN — ready to merge  $url"
    elif [[ "$status" == "RED" ]]; then
      if [[ -n "$(get_skip_sig "$repo")" ]]; then
        reason="$(get_skip_reason "$repo" | cut -c1-200)"
        log "  🟡 $(basename "$repo"): EXPECTED-RED ($sig)  $url"
        [[ -n "$reason" ]] && log "       waiting on: $reason"
      else
        log "  🔴 $(basename "$repo"): RED — unresolved ($sig)  $url"
      fi
    elif [[ "$status" == "PENDING" ]]; then
      log "  ⏳ $(basename "$repo"): CI still running  $url"
    else
      log "  ❓ $(basename "$repo"): $status  $url"
    fi
  done
  log ""
  log "Manual steps for the operator:"
  log "  1. Merge the GREEN PRs in dependency order (the Targets order in $INPUTS)."
  log "  2. EXPECTED-RED PRs clear as upstreams merge / artifacts publish — after"
  log "     merging, re-run to repin downstreams and re-verify:  ./loop.sh $INPUTS"
  if [[ "$has_core_open" == true ]]; then
    log "  3. stellar-core: after its PR merges, trigger the Jenkins vnext deb+docker"
    log "     build — downstream artifact-waits stay red until the matching-commit"
    log "     artifact publishes (see lessons.md)."
  fi
  log "  Status table: $STATUS_FILE"
}

# Count still-running parallel fix jobs (bash 3.2: no wait -n / jobs -p games).
live_fix_jobs() {
  local n=0 p
  for p in $FIX_PIDS; do
    kill -0 "$p" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}

# One red PR's full fix cycle: failure signal → plan_then_review (INVESTIGATE-
# aware) → verdict → execute → RUN_BUILD handoff → harvest new upstream PRs.
# Runs as a BACKGROUND JOB in the fix pass, so:
#   - LOG_PREFIX/REPO_EFFORT are locals — bash dynamic scoping makes them
#     visible to log()/ask_claude() below this frame without leaking to
#     other jobs.
#   - All cross-job effects go through files: state_set is lock-protected,
#     fail-state bookkeeping files are per-repo. SCOPE is NOT mutated here —
#     harvested upstream PRs land in the state file and enter SCOPE at the
#     next iteration's rebuild_scope.
fix_one_repo() {
  local repo="$1" pr="$2" fail_sig="$3"
  local LOG_PREFIX="[$(basename "$repo")] "
  local REPO_EFFORT; REPO_EFFORT="$(effort_for_repo "$repo")"
  # Per-fix-job claude session (its own UUID → own marker file), so parallel fix
  # jobs never share context and the plan → execute → builds chain here reuses
  # its own turns. See ask_claude / open_pr_for_repo.
  local CLAUDE_SESSION_ID; CLAUDE_SESSION_ID="$(new_session_id)"
  local fail_log fix_task fix_plan investigate_n inv_line first_line fix_out
  local new_url new_path

  fail_log="$(failure_signal "$pr")"
  [[ -z "$fail_log" ]] && fail_log="(no failure signal extracted — inspect $pr manually)"
  log "signal:"
  printf '    %s\n' "$fail_log" | head -10

  # Plan a fix. INVESTIGATE-aware: the planner can take extra reading
  # turns before committing to FIX/SKIP. Cap at MAX_INVESTIGATE_ROUNDS.
  fix_task="CI is red on $pr ($(basename "$repo")).

$fail_log

GENERAL PRINCIPLE — judge each failing check against the state of THIS
release. Use 'Open PRs in this run' above: which in-scope PRs are still
OPEN vs already MERGED, plus the dependency layering in the contract.
For EACH failing check, classify it:
  • EXPECTED-NOW — it can only go green after a later step in this run
    that hasn't happened yet. Examples: a git-rev / codegen / dependency
    check failing because it points at an in-scope upstream PR that's
    still OPEN; a check needing a stellar-core deb/image not yet published
    (check the apt pool + unsafe-stellar-core docker repo for an artifact
    whose commit matches the core PR HEAD — see lessons.md); a downstream
    check waiting on an unmerged XDR change. A non-blocking tracker /
    fork-secrets workflow also counts as expected-now.
  • ACTIONABLE-NOW — the work it depends on is already in place and it's
    genuinely broken. Examples: this PR's own unit tests, fmt/lint, a
    compile error in code that depends on nothing unmerged, a generated
    file you can regenerate now, a repin you can do now because the
    upstream it points at has ALREADY MERGED (shown above).
Once an upstream a check was waiting on has MERGED, that check flips from
expected-now to actionable-now — propose the repin/regen that makes it pass.

The fix may belong here OR in an UPSTREAM PR in this run. If upstream,
name the upstream repo + PR URL in your plan.

VERDICT FORMAT (machine-parsed): the FIRST non-empty line of your reply
must be one of:
  - SKIP         — EVERY failing check is expected-now. State which later
                   step each one is waiting on; the script re-checks next pass.
  - FIX          — at least one failing check is actionable-now. Plan the
                   edits below (a repin/regen counts as a fix).
  - INVESTIGATE  — you need another reading pass to classify a check. Write
                   what you've checked and what's still unknown; the script
                   re-invokes you with these findings.
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
    log "planner: INVESTIGATE (round $investigate_n/$MAX_INVESTIGATE_ROUNDS) — re-invoking"
    fix_plan="$(plan_then_review "$fix_task

PRIOR INVESTIGATION (from previous pass — extend your reading and
either commit to SKIP/FIX or INVESTIGATE again with new findings):
$fix_plan" "$repo")"
  done

  # Final verdict detection: SKIP / FIX (default).
  first_line="$(printf '%s' "$fix_plan" | awk 'NF{print; exit}')"
  if printf '%s' "$first_line" | grep -qiE '^\**SKIP\b' \
     || printf '%s' "$fix_plan" | grep -qiE '^[[:space:]]*##.*Verdict.*\bSKIP\b'; then
    log "planner: SKIP this round (verdict: $(printf '%s' "$first_line" | head -c 100))"
    # Cache the SKIP'd signature so future iterations short-circuit until
    # the signature changes (new commit, new failure). Keep a one-line
    # reason for the status table / operator summary.
    set_skip_sig "$repo" "$fail_sig"
    set_skip_reason "$repo" "$(printf '%s\n' "$fix_plan" | awk 'NF' | sed -n '1,3p' | tr '\n' ' ' | cut -c1-300)"
    set_same_fail_count "$repo" 0
    return 0
  fi
  if printf '%s' "$first_line" | grep -qiE '^\**INVESTIGATE\b'; then
    log "planner: still INVESTIGATE after $MAX_INVESTIGATE_ROUNDS rounds — treating as no-action this iter; will retry next iter"
    return 0
  fi
  # Not a SKIP / INVESTIGATE — going to fix something. Clear stale SKIP cache.
  clear_skip_sig "$repo"

  log "EXECUTE (claude): apply fix"
  fix_out="$(cd "$repo" && ask_claude "Apply this fix. The plan names a
target repo. If the target is one of the in-scope checkouts, cd there
and push to its existing PR branch (do NOT open a new PR for it).

NOTE: other fix agents may be running CONCURRENTLY on OTHER repos' PRs.
Touch only the repo(s) your plan names. If a git operation fails because
another process holds the lock (index.lock / cannot lock ref), wait ~10s
and retry.

Build + run tests locally to validate BEFORE pushing:
- Quick builds/tests (cargo/go/pnpm, a few minutes): run them synchronously now.
- A LONG build (a stellar-core compile, or a TxMeta re-record needing a fresh
  binary): do NOT run it yourself and do NOT background it — a -p turn is NOT
  re-invoked, so a backgrounded build strands the run. Make ALL edits first,
  then emit a single \`RUN_BUILD: <cmd>\` line as your LAST line and STOP (do not
  push yet). The script runs it, waits however long it takes, and re-invokes you
  with the result to commit + push. If a command you started gets
  AUTO-BACKGROUNDED by your harness, do NOT end your turn waiting for its
  notification (it never arrives in -p mode) — emit the RUN_BUILD line for
  that command instead.
- For stellar-core, request an INCREMENTAL build that reuses the already-built
  in-tree objects + ccache: \`make -j\$(nproc)\` (run \`./configure
  --enable-next-protocol-version-unsafe-for-production\` only if there's no
  Makefile yet). NEVER \`make clean\` and never a fresh out-of-tree build dir —
  that throws away the warm tree and turns a 2-minute rebuild into an hour.
ALWAYS commit and push before ending your turn — UNLESS you emitted a RUN_BUILD
line (then stop and wait for the re-invoke).

Re-recording stellar-core's \`test-tx-meta-baseline-*\` to make CI pass is
fine (expected when the CAP changes tx semantics or adds tests). Inspect the
diff; if a tx changed that you did NOT expect, note it in the PR for the
reviewer — but still commit and continue, don't block.

If the target is an UPSTREAM repo that does NOT yet have a PR in this
run, clone it into $WORK_DIR/<owner>--<name>/, create a release-named
branch, push to your fork, and open a draft PR AGAINST THE UPSTREAM repo
(cross-fork: \`gh pr create -R stellar/<repo> --base <base-branch> --head
<fork-owner>:<branch>\`) — never fork-internal, never a synthetic base.
Cross-link the open PRs in the description.

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

  # Long-build handoff (e.g. an incremental stellar-core build to validate the
  # fix before pushing): the SCRIPT runs any RUN_BUILD claude requested, waits,
  # and re-invokes it to commit + push to the EXISTING PR.
  run_build_handoff "$repo" "$fix_out" "Now: fix any build fallout, commit ALL changes on the release branch, and push to the EXISTING PR branch (do NOT open a new PR). If the exit code was non-zero, fix the cause first — it may be UPSTREAM (an earlier repo in the dep chain whose PR is open this run): \`cd\` there, push to its existing PR branch, re-pin THIS repo to the upstream's new head, then request another build. OUTPUT: print every PR URL you touched, one per line, at the end. To request ANOTHER build, output a single \`RUN_BUILD: <cmd>\` line as the very last line and stop."
  fix_out="$RUN_BUILD_RESULT"

  # Harvest any newly-opened upstream PR URLs into the state file. SCOPE
  # picks them up at the next iteration's rebuild_scope.
  while IFS= read -r new_url; do
    [[ -z "$new_url" ]] && continue
    if jq -e --arg v "$new_url" 'to_entries[] | select(.value == $v)' "$state_file" >/dev/null; then
      continue
    fi
    new_path="$(find_or_propose_repo_for_pr "$new_url")"
    if [[ -d "$new_path/.git" ]]; then
      log "scope+: $new_url → $new_path (existing checkout; watched from next iter)"
    else
      log "scope+: $new_url → $new_path (claude is expected to have cloned here; watched from next iter)"
    fi
    state_set "$new_path" "$new_url"
  done < <(extract_pr_urls "$fix_out")
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

  # SCOPE = Targets ∪ state-file keys (fix jobs record new upstream PRs in
  # the state file from their subshells; this is where they join the watch).
  rebuild_scope

  rm -rf "$POLL_DIR"; mkdir -p "$POLL_DIR"
  merged_this_iter=()
  all_done=true
  saw_pending=false

  # ---- POLL PASS: one gh fetch per PR → merge state, CI status, fail sig.
  # The full status table is visible within ~a minute, BEFORE any fix work
  # starts (fixes used to be interleaved here, so one slow fix hid the rest
  # of the table for hours). Results land in $POLL_DIR and drive everything
  # below; OPEN→MERGED transition detection rides the same single fetch.
  for repo in "${SCOPE[@]}"; do
    pr="$(state_get "$repo")"
    [[ -z "$pr" || "$pr" == "ESCALATED" ]] && continue
    line="$(poll_pr "$pr")"
    printf '%s\n' "$line" > "$(poll_file "$repo")"
    IFS=$'\t' read -r mstate status sig <<< "$line"

    if [[ "$mstate" == "MERGED" ]]; then
      if [[ "$(get_pr_prev_state "$repo")" != "MERGED" ]]; then
        log "🎉 $(basename "$repo") merged: $pr"
        merged_this_iter+=("$repo")
      fi
      set_pr_prev_state "$repo" "MERGED"
      log "$(basename "$repo"): MERGED ✔ $pr"
      continue
    fi
    # Escalated this run: report-only (still polled for the table + merge
    # detection above, but no fix work and no effect on done/stall flags).
    if is_escalated "$repo"; then
      log "$(basename "$repo"): ESCALATED (frozen this run — operator) $pr"
      continue
    fi
    if [[ "$mstate" == "CLOSED" ]]; then
      log "WARNING: $(basename "$repo") PR was CLOSED without merging — escalating (operator intervened?): $pr"
      set_escalated "$repo"
      continue
    fi
    [[ "$mstate" != "UNKNOWN" && -n "$mstate" ]] && set_pr_prev_state "$repo" "$mstate"

    case "$status" in
      GREEN)   log "$(basename "$repo"): GREEN $pr" ;;
      PENDING) log "$(basename "$repo"): pending $pr"; all_done=false; saw_pending=true ;;
      UNKNOWN) log "$(basename "$repo"): CI unreadable (transient gh error / rate limit) — retry next pass $pr"; all_done=false; saw_pending=true ;;
      RED)     log "$(basename "$repo"): RED $pr"; all_done=false ;;
    esac
    sleep 1   # pace the poll burst — the secondary rate limit bites on bursts
  done

  # Any merge invalidates the OTHER repos' SKIP caches: their planners can
  # now see the merge in the cross-PR context and propose a repin.
  if [[ ${#merged_this_iter[@]} -gt 0 ]]; then
    for repo in "${SCOPE[@]}"; do
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

  # Cross-PR context for every prompt this iteration — built ONCE from the
  # poll table instead of N gh calls inside every planner/review/execute
  # prompt (that per-prompt fan-out is what used to trip the secondary rate
  # limit). Includes each PR's failing checks so a planner fixing repo X
  # sees exactly what's red elsewhere. Refreshed next iteration.
  OPEN_PRS_CACHE=""
  for repo in "${SCOPE[@]}"; do
    url="$(state_get "$repo")"
    if [[ -z "$url" || "$url" == "ESCALATED" ]]; then
      OPEN_PRS_CACHE="${OPEN_PRS_CACHE}- $repo: ${url:-NOT-YET-OPENED}"$'\n'
      continue
    fi
    pf="$(poll_file "$repo")"
    if [[ -f "$pf" ]]; then
      IFS=$'\t' read -r mstate status sig < "$pf"
      OPEN_PRS_CACHE="${OPEN_PRS_CACHE}- $repo: $url [$mstate, CI=$status${sig:+, failing: $sig}]"$'\n'
    else
      OPEN_PRS_CACHE="${OPEN_PRS_CACHE}- $repo: $url [not polled]"$'\n'
    fi
  done

  write_status_file "poll pass done — dispatching fixes next"

  if [[ "${DRY_WATCH:-0}" == "1" ]]; then
    final_summary "DRY_WATCH snapshot (single poll pass; no fixes attempted)"
    exit 0
  fi

  # ---- FIX PASS: dispatch every actionable red as its own background job,
  # up to MAX_PARALLEL_FIXES concurrent. Bookkeeping (skip cache, same-
  # failure escalation) stays HERE in the main shell — cheap file ops, no
  # races — so a job is only spawned when there's real planner work to do.
  any_actionable=false
  FIX_PIDS=""
  fix_names=""

  for repo in "${SCOPE[@]}"; do
    pr="$(state_get "$repo")"
    [[ -z "$pr" || "$pr" == "ESCALATED" ]] && continue
    is_escalated "$repo" && continue
    pf="$(poll_file "$repo")"
    [[ -f "$pf" ]] || continue
    IFS=$'\t' read -r mstate status sig < "$pf"
    [[ "$status" == "RED" && "$mstate" == "OPEN" ]] || continue
    # RED but no parsed signature (an exotic check conclusion) — still
    # actionable; give the caches a deterministic key.
    [[ -z "$sig" ]] && sig="RED-unparsed"

    # Sticky-SKIP short-circuit: previously verdicted SKIP and the failing-
    # check set hasn't changed → known-non-blocking, don't burn another
    # plan-review cycle.
    skip_sig="$(get_skip_sig "$repo")"
    if [[ -n "$skip_sig" && "$skip_sig" == "$sig" ]]; then
      log "  $(basename "$repo"): SKIP (cached — same fail-sig as previous SKIP verdict)"
      continue
    fi

    # Same-failure-N detection per-PR. ESCALATE only after the same
    # signature has persisted MAX_SAME_FAIL_RETRIES retries in a row
    # (default 3 — gives the planner a few attempts to diagnose hard
    # CI failures). (Skipped when the SKIP cache would have matched.)
    prev_sig="$(get_prev_fail_sig "$repo")"
    if [[ "$prev_sig" == "$sig" && -n "$sig" ]]; then
      new_count=$(($(get_same_fail_count "$repo") + 1))
      set_same_fail_count "$repo" "$new_count"
      log "  same failure as previous iter ($(basename "$repo")), retry $new_count/$MAX_SAME_FAIL_RETRIES"
      if [[ "$new_count" -ge "$MAX_SAME_FAIL_RETRIES" ]]; then
        log "  ESCALATE: same failure on $(basename "$repo") for $((new_count + 1)) consecutive iters — frozen for this run (PR kept: $pr)"
        set_escalated "$repo"
        continue
      fi
    else
      set_same_fail_count "$repo" 0
    fi
    set_prev_fail_sig "$repo" "$sig"

    any_actionable=true
    # Block until a parallel slot frees up, then dispatch this repo's full
    # fix cycle (plan → review → execute → build handoff) as its own job.
    while [[ "$(live_fix_jobs)" -ge "$MAX_PARALLEL_FIXES" ]]; do sleep 10; done
    log "  $(basename "$repo"): dispatching fix job ($(( $(live_fix_jobs) + 1 ))/$MAX_PARALLEL_FIXES slots)"
    fix_one_repo "$repo" "$pr" "$sig" &
    FIX_PIDS="$FIX_PIDS $!"
    fix_names="$fix_names $(basename "$repo")"
  done

  if [[ -n "$FIX_PIDS" ]]; then
    write_status_file "fix jobs running:${fix_names} — tail the runlog for live progress"
    log "waiting for fix job(s):${fix_names}"
    for p in $FIX_PIDS; do wait "$p" 2>/dev/null; done
    FIX_PIDS=""
    write_status_file "fix pass done:${fix_names} — repolling next iteration"
  fi

  # ---- Done conditions ----
  if "$all_done"; then
    final_summary "ALL DONE — every watched PR is green or merged"
    # Exit non-zero if any escalated (state or this-run flag); zero otherwise.
    if any_escalated; then
      exit 2
    fi
    exit 0
  fi

  # STALLED: not done, but nothing to fix, nothing in flight, and no fresh
  # merges — every remaining red is verdicted "waiting on a later step".
  # More polling can't make progress; only operator action (merging PRs,
  # publishing artifacts) can. Exit with the TODO list instead of burning
  # the remaining iterations. EXIT_ON_STALL=0 restores poll-to-the-cap.
  if [[ "${EXIT_ON_STALL:-1}" == "1" ]] \
     && [[ "$any_actionable" == false && "$saw_pending" == false ]] \
     && [[ ${#merged_this_iter[@]} -eq 0 ]]; then
    final_summary "STALLED — nothing actionable left; operator action required"
    exit 3
  fi

  if ! "$any_actionable"; then
    log "nothing actionable this pass; sleeping ${WATCH_INTERVAL}s"
  fi
  sleep "$WATCH_INTERVAL"
done

final_summary "MAX_WATCH_ITERS=$MAX_WATCH_ITERS exhausted — not all PRs green"
exit 2
