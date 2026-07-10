# fable-sonnet-orchestrator-kit

Drop-in Claude Code operating model: an orchestrator main agent turns intent
into GitHub issues and fans work out to model-pinned executor subagents
(one issue → one worktree → one PR into `main`), enforced by a code-based
PowerShell stop gate. This clone is a fork (`kninetimmy/...`); upstream is
`NickalasLight/fable-sonnet-orchestrator-kit`.

## Session Continuity

memhub is the source of truth at `.memhub/project.sqlite`. The rendered
views under `.memhub/rendered/` (PROJECT.md, PROJECT_LEDGER.md) are
generated, machine-local, and gitignored. Re-render after `/wrap-up` with
`memhub render`. Read PROJECT.md at session start before acting.

## Build / test / run

None — this is a config-only kit (markdown skills/agents plus one
PowerShell 7 hook script). Verification is behavioral: dispatch probes and
live PR loops. See Architecture in the rendered PROJECT.md.

## Working on this repo

This repo is SOURCE MATERIAL for the user-scope orchestrator-mode install
at `~/.claude` (see ORCHESTRATOR-MODE-SKETCH.md). Changing files here does
NOT change the deployed orchestrator mode — port changes deliberately in
either direction, and keep the Claude Code 2.1.x compatibility notes in
README.md in sync with the stop gate's actual contract.
