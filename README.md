# fable-sonnet-orchestrator-kit

A drop-in **Claude Code** operating model: your main agent becomes an **orchestrator** that fans
work out to focused **Sonnet executor** subagents and drives everything through a
**GitHub issue → git worktree → PR → review → merge** loop. A **code-based Stop hook** (not a
model's memory) enforces the hand-offs, so the loop can't silently break.

## Install

Drop the `.claude/` folder into your project root (merge with any existing `.claude/`). Then
search-and-replace three placeholders: `<YOUR_ORG>` (GitHub owner), `<REPO_ROOT>` (local checkout
path, forward slashes), `<ENV_VALUES_DIR>` (an out-of-repo secrets dir). Tune the label and
conflict-file lists to your codebase.

**Prerequisites:** [Claude Code](https://docs.claude.com/en/docs/claude-code), the
[`gh` CLI](https://cli.github.com/) authenticated non-interactively, and PowerShell 7+ (`pwsh`)
for the Stop hook.

## Use

Open Claude Code in that project and give it a clean manager prompt, e.g.:

> You are the orchestrator. Break my request into GitHub issues and dispatch `sonnet-executor`
> subagents per the `fable-orchestrator` skill.

The `SessionStart` hook auto-injects the orchestrator operating model each session, so the main
agent always boots knowing its role.

## How it works

The orchestrator turns intent into clean, single-PR-sized GitHub issues (issues *are* the todo
list), then spawns one `sonnet-executor` subagent per `ready` issue. Each executor makes a git
worktree, does the smallest correct change with targeted tests, and opens one PR into `main` with
`Closes #N`. The `executor-stop-gate.ps1` Stop hook gates every turn-end in code: no PR → block
until one exists; changes requested (a `[ORCH-REVIEW] CHANGES-REQUESTED` PR comment) → block and
inject the review so it's fixed now; merged/approved → allow. The orchestrator is the sole
reviewer/merger — **merging is the approval signal**. The `handoff` skill keeps a single
`handoff.md` as rolling memory so a fresh agent can take over after a compaction or crash.

**Why the asymmetry (orchestrator vs. executors).** The orchestrator is the **main agent** itself —
it has no agent definition; instead the `fable-orchestrator` skill is auto-injected each session by
the `SessionStart` hook, which is what configures the main agent into its orchestrator role. The
executors (`sonnet-executor`, `issue-triage`) are **subagents** spawned via the Agent tool, so each
one *does* need an agent definition (pinning its model, effort, tools, and Stop hook) paired with a
matching skill. Main-agent role → skill only; spawned subagent → agent def **plus** skill.

## IMPORTANT — model config (the #1 cost gotcha)

The executor and triage agents are pinned to `model: claude-sonnet-4-6` + `effort: max` on purpose:
the exact version id **enforces** that every dispatched subagent runs on Sonnet 4.6 at max thinking,
rather than a floating `sonnet` alias that could drift to a pricier tier. But some Claude Code setups
make subagents **inherit the session model** instead of honoring the agent's `model:` frontmatter. So:

- Keep your **main session on a strong model** (e.g. Opus/Fable) for orchestration judgment.
- **Verify your dispatched executors actually run on Sonnet 4.6**, not the expensive main model. If
  they inherit the session model, pass the model explicitly on each dispatch.
- To move to a newer Sonnet later, update the `model:` line in each `.claude/agents/*.md` (and this
  note) to the new id — the pin is deliberate, so change it deliberately.

## Security

These files contain **no secrets, tokens, or credentials** — only references to *where* secrets
should live (your out-of-repo `<ENV_VALUES_DIR>`). Keep real secrets outside any repo.
