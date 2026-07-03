# fable-sonnet-orchestrator-kit

A drop-in **Claude Code** operating model: your main agent becomes an **orchestrator** that turns
intent into GitHub issues and fans work out to model-pinned **executor subagents** — one issue,
one git worktree, one PR into `main`. A **code-based PowerShell Stop hook** (not a model's
memory) enforces every hand-off, so the loop cannot silently break.

Two human gates bracket the autonomous work: a **plan gate** before any issue is created (you
approve the issue list, model tiers, and dispatch waves), and a per-PR **merge gate** where you
confirm each passing PR before the orchestrator merges. Everything between — dispatch, executor
work, the review loop — runs without interruption.

## Prerequisites

- [Claude Code](https://docs.claude.com/en/docs/claude-code) (2.1.x verified; earlier versions
  may work)
- [`gh` CLI](https://cli.github.com/) authenticated **non-interactively** (credential store — no
  interactive prompts)
- **PowerShell 7+** (`pwsh`) on your `PATH`, for the Stop hook

## Install

Drop the `.claude/` folder from this repo into your project root (merge with any existing
`.claude/`). Then search-and-replace three placeholders in the skill and executor files:

| Placeholder | Replace with |
|---|---|
| `<YOUR_ORG>` | GitHub owner / org |
| `<REPO_ROOT>` | Local checkout root, **forward slashes** |
| `<ENV_VALUES_DIR>` | An out-of-repo directory for secrets |

Tune the label list and conflict-file list in `.claude/skills/fable-orchestrator/SKILL.md` to
your codebase (conflict-prone files, one DB migration in flight at a time, etc.).

> **Evolving to a user-scope install with a per-repo toggle?** `ORCHESTRATOR-MODE-SKETCH.md`
> documents the finalized design for installing the agents, skills, and hook at `~/.claude/`
> (one copy serves many repos) and toggling orchestrator mode per-repo with
> `/orch on` | `/orch off` | `/orch status`. It is ready to implement from that document alone.

## Use

Open Claude Code in your project. The `SessionStart` hook auto-injects the `fable-orchestrator`
skill every session, so the main agent always boots into its orchestrator role — no manual prompt
needed.

When you describe a task, the session runs as follows:

1. **Plan gate** — the orchestrator restates your request, decomposes it into a list of GitHub
   issues (each with a title, one-line objective, model tier, and dependencies), and presents the
   full plan for your approval **before creating anything on GitHub**. Model tiers are visible and
   overridable here.
2. **Fan-out** — on approval, the orchestrator dispatches one executor subagent per `ready` issue:
   `sonnet-executor` (default, `tier:sonnet`) or `opus-executor` (`tier:opus`). Independent issues
   run in parallel (up to 3-4 concurrent); conflict-prone issues serialize.
3. **Review loop** — each executor opens a PR. The orchestrator reviews it immediately (full diff,
   acceptance-criteria checklist, test evidence). Approved PRs come to you as a ready-to-merge
   report; change requests are fed back to the executor through the Stop gate automatically —
   the executor cannot end its turn until it addresses every point.
4. **Merge gate** — the orchestrator presents each passing PR and waits for your confirmation. On
   your word, it merges, confirms the issue auto-closed, removes the executor's worktree, and
   prunes.

## How it works

**Issue → worktree → PR → review → human merge.** Every unit of work is a GitHub issue before any
code is written. The orchestrator dispatches one executor subagent per ready issue; the executor
creates a git worktree off `main`, makes the smallest correct change with bespoke targeted tests,
and opens one PR into `main` with `Closes #N`. The orchestrator reviews, requests changes if
needed (iterating until the PR is clean), and surfaces a ready-to-merge report to you.

**Code-based Stop gate.** `executor-stop-gate.ps1` fires at every executor turn-end via a
`SubagentStop` hook. It gates three cases:

- No PR opened and no `BLOCKED:` declaration → block once, telling the executor to open the PR
- Changes requested (a PR comment starting `[ORCH-REVIEW] CHANGES-REQUESTED`, or a formal
  request-changes review from a different GitHub account) with no fix commit since → block and
  inject the full review so the executor addresses it now
- Merged, closed, approved, or awaiting review → allow; the harness task-notification tells the
  orchestrator the executor finished

The gate is **fail-open**: any parse, network, or `gh` failure allows the stop — tooling breakage
never traps an agent.

**Orchestrator vs. executor asymmetry.** The orchestrator is the main agent itself — it needs no
agent definition. The `fable-orchestrator` skill is auto-injected every session by the
`SessionStart` hook, which is what boots the main agent into its orchestrator role. The executors
(`sonnet-executor`, `opus-executor`, `issue-triage`) are subagents spawned via the Agent tool, so
each needs an agent definition (pinning model, effort, and tools) paired with a matching skill;
the executor Stop gate is wired in `.claude/settings.json` as a `SubagentStop` hook.
Main-agent role → skill only; spawned subagent → agent definition **plus** skill.

## Works with memhub

[memhub](https://github.com/kninetimmy/memhub) is a SQLite-backed rolling-memory system for
Claude Code. This operating model uses memhub as its single source of rolling project memory —
there is no separate rolling-memory file.

The orchestrator runs **`/wrap-up` at milestones** (merges, architecture decisions,
newly-learned gotchas); memhub's own approval gates stay intact. Executors **never write** to
`agent_docs/`, `PROJECT.md`, or `PROJECT_LEDGER.md` — those are orchestrator/memhub-owned
(K9 rule: subagent writes there are forbidden).

At session start, read `PROJECT.md` if the repo has one — that is the canonical project state.

## Compatibility notes (Claude Code 2.1.x, Windows — verified empirically)

- Hook command strings execute through **Git Bash**, even on Windows. Use bash-expanded
  `$CLAUDE_PROJECT_DIR` in `settings.json` hook commands — pwsh-style `$env:VAR` gets mangled
  (bash expands `$env` to empty) before PowerShell ever runs.
- `hooks:` declared in agent **frontmatter never fire**. The executor Stop gate is therefore
  registered in `.claude/settings.json` under `SubagentStop` with
  `"matcher": "sonnet-executor|opus-executor"`, so no other subagent is gated.
- A `SubagentStop` hook **blocks by printing `{"decision":"block","reason":"..."}` to stdout**
  (exit 0). Exit code 2 + stderr — the classic Stop-hook contract — is treated as a non-blocking
  error and the subagent stops anyway. The gate also reads the executor's transcript from
  `agent_transcript_path`; `transcript_path` in SubagentStop input is the *parent* session's.

## IMPORTANT — model config (the #1 cost gotcha)

Executors are pinned in their agent definition files:

| Agent | `model:` pin | When dispatched |
|---|---|---|
| `sonnet-executor` | `claude-sonnet-5` | Default — all `tier:sonnet` issues |
| `opus-executor` | `claude-opus-4-8` | `tier:opus` only — ambiguous debugging, architecture-adjacent work |
| `issue-triage` | `claude-sonnet-5` | GitHub-issue bookkeeping clerk |

All executors run at `effort: max`. The exact version IDs **enforce** the right model on each
dispatch. But some Claude Code setups make subagents **inherit the session model** instead of
honoring the agent's `model:` frontmatter. So:

- Keep your **main session on a strong model** (e.g. Opus 4.8) for orchestration judgment.
- **Verify dispatched executors run on their pinned model**, not the expensive main-session model.
  If they inherit the session model, pass the model explicitly on each dispatch.
- `tier:opus` dispatches are Opus-rate calls — the plan gate is where you keep an eye on that.
- To update a pin later, edit the `model:` line in the relevant `.claude/agents/*.md` file — the
  pin is deliberate, so change it deliberately.

## Security

These files contain **no secrets, tokens, or credentials** — only references to *where* secrets
should live (your out-of-repo `<ENV_VALUES_DIR>`). Keep real secrets outside any repo.
