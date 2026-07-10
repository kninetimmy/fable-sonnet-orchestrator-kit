---
name: orch
description: Toggle Codex orchestrator mode for the current repository with $orch on, $orch off, or $orch status. Manage the gitignored .codex/orch.on flag, adopt or drop the operating model immediately, and report work in flight.
---

# $orch — Codex orchestrator-mode toggle

Argument: `on` | `off` | `status`. No argument → treat as `status`.

## on
1. Create the empty flag file `.codex/orch.on` in the current repo root (create `.codex/` if
   it doesn't exist).
2. Ensure it is gitignored: if the repo's root `.gitignore` doesn't already cover
   `.codex/orch.on`, append that line (create `.gitignore` at the repo root if the repo has
   none).
3. Read `../orchestrator/SKILL.md` completely and adopt it as your operating model NOW — the mode
   takes effect mid-session. New sessions in this repo get it auto-injected by the plugin's
   `SessionStart` hook while the flag exists.
4. Confirm to the user: mode on, flag path, and that the operating model requests parallel
   executor dispatch of at most 3–4 agents while the flag is set.

## off
1. Delete `.codex/orch.on`.
2. Explicitly revert: state "orchestrator mode off; resuming the traditional workflow; all global
   Codex rules unchanged" — and drop the orchestrator operating model for the rest of the
   session.
3. In-flight executors finish their current PR and park (their stop gate allows stopping while a
   PR awaits review) — dispatch nothing new. List any open executor PRs so the human can decide
   what happens to them.

## status
1. Report whether `.codex/orch.on` exists (mode ON / OFF).
2. If ON, report what's in flight:
   - open executor PRs: `gh pr list --author "@me" --state open`
   - live worktrees: `git worktree list`
3. One compact report; change nothing.
