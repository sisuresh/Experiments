#!/usr/bin/env python3
"""Author a protocol-release PR stack: per repo, plan (frontier model) then
implement (cheaper model, resuming the planner's context).

    ./author.py releases/p28-cap-0084.md                    # dry run: plan only
    ./author.py releases/p28-cap-0084.md --only rs-stellar-xdr
    ./author.py releases/p28-cap-0084.md --write            # actually edit/push

Spine repos run sequentially (each repin needs the previous head SHA); leaf
repos run in parallel (they depend on the spine, not on each other).
"""
from __future__ import annotations

import argparse
import asyncio
import re
import sys
from datetime import datetime
from pathlib import Path

from lib import (
    EFFORTS,
    MODELS,
    Handoff,
    Repo,
    base_sha,
    chain_context,
    load_plans,
    load_repo,
    load_state,
    read_base,
    run_agent,
    save_plan,
    save_state,
    say,
)

HANDOFF_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["prUrl", "headSha", "notes"],
    "properties": {
        "prUrl": {"type": "string", "description": "PR URL opened or updated for this repo"},
        "headSha": {"type": "string", "description": "full head SHA pushed"},
        "notes": {
            "type": "string",
            "description": "ONE line: pins set + decisions downstream repos must know",
        },
    },
}


def parse_targets(release: str) -> list[str]:
    """Repo names from the release file's '## Targets' bullet list, in dep order."""
    m = re.search(r"(?:^|\n)##\s+Targets[^\n]*\n(.*?)(?=\n##\s|\Z)", release, re.S)
    if not m:
        return []
    return [b.group(1) for b in re.finditer(r"^\s*-\s+(\S+)", m.group(1), re.M)]


def plan_prompt(r: Repo, release: str, base: str, chain: str) -> str:
    return f"""{base}

## This repo: {r.name}
Checkout: {r.path}
Base branch: {r.base}

{r.prompt}

## Release
{release}

## Already landed this run (upstream → downstream)
{chain}

## Your task
PLAN ONLY — make no edits, open nothing, push nothing.

Read what you need (this repo, the base branch, the upstreams' pushed heads
above) and produce an implementation-ready plan: exact files, exact edits,
exact commands, exact pins/SHAs, and how to verify. Another agent will execute
it verbatim without re-deriving your reasoning — if a step is ambiguous, it
will be done wrong. Be concrete, not narrative.

If the correct action is "nothing to do here", say so in one line and stop."""


def impl_prompt(r: Repo) -> str:
    # The implementer resumes the planner's session, so it already holds the
    # plan and the repo exploration. Keep this short on purpose.
    return f"""Execute the plan you just produced for {r.name}, in full.

Rules:
- Work in {r.path} on a release branch off the latest {r.base}.
- If a PR already exists for this branch, push new commits to it — merge the
  base in if needed; never rebase or force-push a pushed branch.
- Build/test before pushing. Long builds are fine — run them and wait.
- Open/update ONE draft PR for this repo against the upstream repo (cross-fork:
  gh pr create -R stellar/<repo> --base {r.base} --head <fork>:<branch>).
- Follow the output-style rules from the shared conventions: sparse comments,
  PR description ≤10 lines.

Return the handoff object: prUrl, headSha (full), and a ONE-LINE note stating
the pins you set and any decision a downstream repo must mirror."""


async def author_repo(r: Repo, ctx: dict) -> Handoff | None:
    plan_session: str | None = None
    plan_text = ""

    # Reuse a saved plan session when one exists and the base hasn't moved
    # under it — that skips the expensive exploration entirely.
    if ctx["reuse_plans"]:
        saved = ctx["plans"].get(r.name)
        if saved and saved.get("session_id"):
            now = base_sha(r.path, r.base)
            was = saved.get("base_sha")
            if now and now == was:
                say(f"↻ {r.name}: reusing plan from {saved.get('at', '?')} "
                    f"(session {saved['session_id'][:8]}, base unchanged)")
                plan_session, plan_text = saved["session_id"], saved.get("plan", "")
            else:
                say(f"↻ {r.name}: saved plan is stale (base {str(was)[:8]} → "
                    f"{str(now)[:8]}) — re-planning")

    if not plan_session:
        plan = await run_agent(
            label=f"plan:{r.name}",
            prompt=plan_prompt(r, ctx["release"], ctx["base"],
                               chain_context(ctx["order"], ctx["state"])),
            cwd=r.path, model=r.plan_model, effort=r.plan_effort, write=False, max_turns=60,
        )
        if not plan.ok:
            say(f"✗ {r.name}: planning failed ({plan.subtype}) — skipping")
            return None
        plan_session, plan_text = plan.session_id, plan.text
        # Save it even on a plan-only run: that is exactly the case where the
        # exploration would otherwise be thrown away.
        if plan_session:
            save_plan(ctx["release_id"], r.name, {
                "session_id": plan_session,
                "at": datetime.now().isoformat(timespec="seconds"),
                "base_sha": base_sha(r.path, r.base),
                "model": r.plan_model, "effort": r.plan_effort,
                "cost_usd": round(plan.cost_usd, 4), "turns": plan.turns,
                "plan": plan_text,
            })
            say(f"   saved plan session {plan_session[:8]} for reuse "
                f"(--reuse-plans)")

    if ctx["plan_only"]:
        say(f"— {r.name}: plan-only, not implementing")
        print(f"\n──── PLAN: {r.name} ────\n{plan_text}\n", flush=True)
        return None

    # Context reuse: resume the planner's session so the implementer inherits
    # the plan AND the repo exploration instead of paying to rediscover both.
    impl = await run_agent(
        label=f"impl:{r.name}", prompt=impl_prompt(r), cwd=r.path,
        model=r.impl_model, effort=r.impl_effort, write=True,
        resume=plan_session, schema=HANDOFF_SCHEMA, max_turns=150,
    )
    if not impl.ok:
        say(f"✗ {r.name}: implementation failed ({impl.subtype})")
        return None

    h = impl.structured if isinstance(impl.structured, dict) else None
    if not h or not h.get("prUrl") or not h.get("headSha"):
        say(f"✗ {r.name}: no usable handoff returned")
        return None

    ctx["state"][r.name] = h
    save_state(ctx["release_id"], ctx["state"])
    say(f"✓ {r.name}: {h['prUrl']} @ {h['headSha'][:8]}")
    return h


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("release_file")
    ap.add_argument("--only", help="just these repos (comma-separated), in dep order")
    ap.add_argument("--from", dest="from_", help="start at this repo, continue down the chain")
    ap.add_argument("--write", action="store_true", help="actually edit, build, push, open PRs")
    ap.add_argument("--plan-only", action="store_true", help="force dry even with --write")
    ap.add_argument("--print-prompt", action="store_true",
                    help="print the exact prompts that would be sent, then exit "
                         "(no model calls, no logs, costs nothing)")
    ap.add_argument("--reuse-plans", action="store_true",
                    help="reuse saved plan sessions from an earlier run instead of "
                         "re-planning; stale plans (base branch moved) are re-planned")
    ap.add_argument("--plan-model", choices=list(MODELS), help="override every repo's plan model")
    ap.add_argument("--plan-effort", choices=EFFORTS, help="override every repo's plan effort")
    ap.add_argument("--impl-model", choices=list(MODELS), help="override every repo's impl model")
    ap.add_argument("--impl-effort", choices=EFFORTS, help="override every repo's impl effort")
    a = ap.parse_args()

    release = Path(a.release_file).read_text()
    release_id = Path(a.release_file).stem
    order = parse_targets(release)
    if not order:
        sys.exit(f'no "## Targets" list found in {a.release_file}')

    repos = [load_repo(n) for n in order]
    for r in repos:   # CLI overrides beat per-repo frontmatter
        r.plan_model = a.plan_model or r.plan_model
        r.plan_effort = a.plan_effort or r.plan_effort
        r.impl_model = a.impl_model or r.impl_model
        r.impl_effort = a.impl_effort or r.impl_effort
    if a.only:
        want = [n.strip() for n in a.only.split(",") if n.strip()]
        unknown = [n for n in want if n not in order]
        if unknown:
            sys.exit(f"unknown repo(s) {unknown} — targets are: {', '.join(order)}")
        repos = [r for r in repos if r.name in want]   # keeps dep order
    if a.from_:
        names = [r.name for r in repos]
        if a.from_ in names:
            repos = repos[names.index(a.from_):]
    if not repos:
        sys.exit("no repos selected")

    ctx = {
        "release": release, "release_id": release_id, "order": order,
        "base": read_base(), "state": load_state(release_id),
        "plan_only": a.plan_only or not a.write,
        "reuse_plans": a.reuse_plans, "plans": load_plans(release_id),
    }

    # Inspect what the agents would actually receive. Deliberately placed before
    # the first say() so it creates no log directory and touches nothing.
    if a.print_prompt:
        chain = chain_context(order, ctx["state"])
        for r in repos:
            p = plan_prompt(r, release, ctx["base"], chain)
            i = impl_prompt(r)
            print("=" * 78)
            print(f"# {r.name}  [{r.group}]  "
                  f"{r.plan_model}/{r.plan_effort} → {r.impl_model}/{r.impl_effort}")
            print(f"# cwd: {r.path}   base: {r.base}")
            print("=" * 78)
            print(f"\n----- PLAN PROMPT ({len(p)} chars, read-only tools) -----\n{p}")
            print(f"\n----- IMPL PROMPT ({len(i)} chars, sent into the resumed "
                  f"plan session) -----\n{i}\n")
        return

    spine = [r for r in repos if r.group == "spine"]
    leaves = [r for r in repos if r.group == "leaf"]
    say(f"release {release_id} · {len(repos)} repo(s) · "
        f"{'WRITE' if a.write and not a.plan_only else 'DRY RUN (plan only)'}")
    say(f"spine: {' → '.join(r.name for r in spine) or '(none)'}")
    say(f"leaves: {', '.join(r.name for r in leaves) or '(none)'}")

    for r in spine:                     # sequential: each repin needs the last head
        await author_repo(r, ctx)
    if leaves:                          # independent of each other
        # return_exceptions: one failed leaf must not cancel its siblings.
        await asyncio.gather(*(author_repo(r, ctx) for r in leaves), return_exceptions=True)

    say("done")
    if ctx["state"]:
        say("chain:")
        print(chain_context(order, ctx["state"]), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
