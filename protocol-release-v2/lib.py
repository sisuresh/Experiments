"""Shared plumbing: prompt loading, agent invocation, state, logging.

Deliberately small — anything the LLM can decide for itself lives in
prompts/, not here.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Literal

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    query,
)

ROOT = Path(__file__).resolve().parent

MODELS = {
    "opus": "claude-opus-5",
    "sonnet": "claude-sonnet-5",
    "haiku": "claude-haiku-4-5-20251001",
}
Effort = Literal["low", "medium", "high", "xhigh", "max"]

READ_TOOLS = ["Read", "Glob", "Grep", "Bash", "WebFetch"]
WRITE_TOOLS = READ_TOOLS + ["Edit", "Write", "MultiEdit", "NotebookEdit"]


# --------------------------------------------------------------- repo config
# One file per repo: prompts/<repo>.md. Frontmatter is the repo's config, the
# body is its custom prompt. Config and guidance live together, so adding a
# repo is one new file rather than an edit in three places.
@dataclass
class Repo:
    name: str
    path: Path      # local checkout
    base: str       # base branch for its PR
    group: str      # "spine" (sequential) | "leaf" (parallel)
    plan_model: str
    impl_model: str
    plan_effort: Effort
    impl_effort: Effort
    prompt: str     # freeform body


def load_repo(name: str) -> Repo:
    f = ROOT / "prompts" / f"{name}.md"
    if not f.exists():
        raise SystemExit(f"no prompt file for repo {name!r} ({f})")
    raw = f.read_text()
    if not raw.startswith("---\n") or "\n---\n" not in raw:
        raise SystemExit(f"{f}: missing --- frontmatter ---")
    fm_text, body = raw[4:].split("\n---\n", 1)
    fm: dict[str, str] = {}
    for line in fm_text.splitlines():
        if ":" in line and not line.startswith("#"):
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip()

    def need(k: str) -> str:
        if not fm.get(k):
            raise SystemExit(f"{f}: frontmatter missing {k!r}")
        return fm[k]

    return Repo(
        name=name,
        path=Path(os.path.expanduser(need("path"))),
        base=need("base"),
        group="spine" if need("group") == "spine" else "leaf",
        plan_model=fm.get("plan_model", "opus"),
        impl_model=fm.get("impl_model", "sonnet"),
        plan_effort=fm.get("plan_effort", "high"),   # type: ignore[arg-type]
        impl_effort=fm.get("impl_effort", "medium"),  # type: ignore[arg-type]
        prompt=body.strip(),
    )


def read_base() -> str:
    return (ROOT / "prompts" / "_base.md").read_text().strip()


# --------------------------------------------------------------------- state
# repo -> handoff. Doubles as the resume record and as the curated "chain
# context" every downstream agent reads instead of re-deriving upstream work.
Handoff = dict[str, str]   # {prUrl, headSha, notes}
State = dict[str, Handoff]


def _state_file(release_id: str) -> Path:
    return ROOT / "state" / f"{release_id}.json"


def load_state(release_id: str) -> State:
    f = _state_file(release_id)
    return json.loads(f.read_text()) if f.exists() else {}


def save_state(release_id: str, state: State) -> None:
    f = _state_file(release_id)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(state, indent=2) + "\n")


def chain_context(order: list[str], state: State) -> str:
    """The point of context reuse: a downstream agent gets a 3-line summary of
    what upstreams did, not a re-exploration of five repos."""
    lines = [
        f"- {r}: {state[r]['prUrl']} @ {state[r]['headSha']} — {state[r]['notes']}"
        for r in order
        if r in state
    ]
    return "\n".join(lines) if lines else "(nothing landed yet this run)"


# ------------------------------------------------------------------- logging
RUN_TS = datetime.now().strftime("%Y%m%d-%H%M%S")


def _log_dir() -> Path:
    d = ROOT / "logs" / RUN_TS
    d.mkdir(parents=True, exist_ok=True)
    return d


def log_path(name: str) -> Path:
    safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
    return _log_dir() / f"{safe}.log"


def say(msg: str) -> None:
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    with (_log_dir() / "run.log").open("a") as fh:
        fh.write(line + "\n")


def _cost_row(row: list[Any]) -> None:
    f = _log_dir() / "cost.tsv"
    new = not f.exists()
    with f.open("a") as fh:
        if new:
            fh.write("time\tlabel\tmodel\teffort\tturns\tin\tout\tcache_read\tcost_usd\n")
        fh.write("\t".join(str(c) for c in row) + "\n")


# -------------------------------------------------------------- agent runner
@dataclass
class RunResult:
    text: str = ""
    structured: Any = None
    session_id: str | None = None
    cost_usd: float = 0.0
    turns: int = 0
    ok: bool = False
    subtype: str | None = None


async def run_agent(
    *,
    label: str,
    prompt: str,
    cwd: Path,
    model: str,
    effort: Effort,
    write: bool,
    schema: dict[str, Any] | None = None,
    resume: str | None = None,
    max_turns: int = 120,
    max_budget_usd: float | None = None,
) -> RunResult:
    log = log_path(label)
    model_id = MODELS[model]

    def w(s: str) -> None:
        with log.open("a") as fh:
            fh.write(s)

    say(f"▶ {label} ({model_id}/{effort}{', resumed' if resume else ''}"
        f"{'' if write else ', read-only'}) → {log}")
    w(f"### {label}\ncwd: {cwd}\nmodel: {model_id} effort={effort}\n"
      f"resume: {resume or '(new)'}\n\n--- PROMPT ---\n{prompt}\n\n--- TRANSCRIPT ---\n")

    opts: dict[str, Any] = dict(
        cwd=str(cwd),
        model=model_id,
        effort=effort,
        allowed_tools=WRITE_TOOLS if write else READ_TOOLS,
        # A headless release driver has to edit, build and push with nobody at
        # the keyboard. Writes are confined to one checkout per agent and gated
        # on --write at the CLI; dry runs never reach this branch.
        permission_mode="bypassPermissions" if write else "dontAsk",
        setting_sources=["project"],   # pick up the repo's own CLAUDE.md
        max_turns=max_turns,
    )
    if resume:
        opts["resume"] = resume
    if schema:
        opts["output_format"] = {"type": "json_schema", "schema": schema}
    if max_budget_usd:
        opts["max_budget_usd"] = max_budget_usd

    res = RunResult()
    try:
        async for m in query(prompt=prompt, options=ClaudeAgentOptions(**opts)):
            if isinstance(m, AssistantMessage):
                for b in m.content:
                    if isinstance(b, TextBlock) and b.text:
                        w(f"\n[text]\n{b.text}\n")
                    elif isinstance(b, ToolUseBlock):
                        w(f"\n[tool] {b.name} {json.dumps(b.input)[:300]}\n")
                        if b.name == "Bash":
                            say(f"   · {label}: {str(b.input.get('command'))[:110]}")
            elif isinstance(m, ResultMessage):
                res.subtype = m.subtype
                res.session_id = m.session_id
                res.ok = m.subtype == "success" and not m.is_error
                if res.ok:
                    res.text = m.result or ""
                    res.structured = m.structured_output
                res.cost_usd = m.total_cost_usd or 0.0
                res.turns = m.num_turns or 0
                u = m.usage or {}
                _cost_row([
                    datetime.now().strftime("%H:%M:%S"), label, model_id, effort, res.turns,
                    u.get("input_tokens", 0), u.get("output_tokens", 0),
                    u.get("cache_read_input_tokens", 0), f"{res.cost_usd:.4f}",
                ])
                w(f"\n--- RESULT {m.subtype} | turns={res.turns} | ${res.cost_usd:.4f} ---\n")
                say(f"   {'✓' if res.ok else '✗'} {label}: {m.subtype} · "
                    f"{res.turns} turns · ${res.cost_usd:.2f}")
    except Exception as e:  # a failed repo must not kill the run
        w(f"\n--- THREW ---\n{e!r}\n")
        say(f"   ✗ {label} threw: {e}")
    return res
