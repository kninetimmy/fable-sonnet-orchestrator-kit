---
name: handoff
description: >-
  Maintain `handoff.md` at the meta-repo root as the single, curated, never-stale ROLLING MEMORY
  of the whole project — current development status AND every durable learned truth — so any
  brand-new agent with zero foreknowledge can fully take over. This is an ORCHESTRATOR-ONLY duty.
  Use it: (1) the moment a context compaction/summary/handoff is imminent — flush the live context
  window into handoff.md FIRST; (2) after any milestone, merge, decision, architecture change, or
  newly-learned gotcha that changes durable state; (3) at session start, to READ handoff.md before
  acting; (4) whenever asked to update/regenerate/fix the handoff. Core rule: ACCRETE + CURATE,
  never blind-overwrite — preserve durable truths, supersede only what is truly stale.
---

# Handoff skill — curate `handoff.md` as the project's rolling memory

`handoff.md` (at your meta/root repo) is the **defacto rolling memory of the entire project**. It
is the one artifact that lets a fresh agent (no chat history, no context) resume development
completely. Treat it as a living document you continuously curate — not a one-off dump.

## When to update (triggers)
- **Compaction imminent** (context is long / a summary is about to happen / user says "compact",
  "handoff", "update handoff") → **update handoff.md FIRST**, harvesting everything still-relevant
  from the live context window before it is lost.
- **After milestones**: a PR merged, an epic completed, a decision made, a bug's root cause
  learned, an architecture/env change, a new gotcha discovered, a subagent's important findings.
- **On session start / after a crash**: READ handoff.md first; then reconcile it against
  `git status`, open PRs/issues, and running processes before acting.
- **On request**: any "regenerate / fix / update the handoff".

## The prime rule: ACCRETE + CURATE, do not blind-overwrite
`handoff.md` accumulates durable truth over the whole project. When updating:
1. **READ the current handoff.md first** (and, if it was recently overwritten, recover the prior
   version from git: `git show <rev>:handoff.md`). Never discard durable content you did not
   consciously decide is stale.
2. **Merge, don't replace**: keep every still-true durable fact; update the moving parts; delete
   only what is genuinely obsolete (prefer moving obsolete-but-historical items to a short
   "superseded" note over deleting the lesson).
3. **Curate for a stranger**: write so an agent with NO foreknowledge can take over. Spell out
   repo layout, how to run things, secrets locations, and the *why* behind non-obvious decisions.
4. **Keep it tight but complete**: durable truths + current status. Don't let it bloat with dead
   detail, but never drop a hard-won lesson or a load-bearing fact.

## Required contents (a fresh agent must be able to fully take over)
Keep these sections present and current:
1. **READ-FIRST / crash recovery** — what's in flight right now; if services/subagents died,
   exactly how to restart the stack (commands + env) and what to re-dispatch.
2. **What the product IS** — the product, the repos + their branches/roles, and the high-level
   architecture. Enough that a stranger understands the system.
3. **Active goal(s)** — the current Stop-hook/goal verbatim intent + acceptance criteria.
4. **Current status** — what's built/merged vs in-progress vs blocked; the epic map with per-child
   status; the migration head; what's proven vs pending.
5. **Learned truths / load-bearing gotchas** — the durable lessons that cost real time if
   forgotten (migration serialization, test-pinning, ff-locals, forward-slash worktree paths,
   fix-breaks-existing-tests, merge-guard pitfalls, etc.). NEVER drop these.
6. **Operating model** — orchestrator vs executor roles, issue flags, git auth, commit trailer,
   merge style, secrets locations (out-of-repo, never commit).
7. **Env / how to run** — how to start each service + the exact env vars/keys; seeded users;
   feature flags.
8. **In-flight + ordered next steps** — including any crashed/lost work to recover (branch names).

## How to update from the context window before compaction
- Scan the live context for: merges/decisions/root-causes since the last handoff, any subagent's
  reported findings (extract from their transcript under
  `~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl` if their `.output` is empty
  — the harness `.output` can truncate on crash), the current running-process/stack state, and the
  exact next action.
- Fold those into the relevant sections; refresh moving numbers (migration head, open PRs, epic
  child status); re-verify "gotchas" still apply and add any new one.

## Persistence (the handoff must survive)
- `handoff.md` lives at the meta-repo root and is committed + pushed to `origin`. Commit with the
  standard trailer and push after each meaningful update — do not rely on autosave alone (it has
  silently failed before).

## Guardrails
- Orchestrator-only; executors do their one issue and do not touch handoff.md.
- Secrets: never write real keys/tokens into handoff.md — reference the out-of-repo secrets dir.
- One canonical handoff.md — supersede in place; do not fork copies.
