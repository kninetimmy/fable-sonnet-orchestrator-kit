# fable-sonnet-orchestrator-kit

This repository is source material for the user's Claude Code and Codex orchestrator-mode
installations. The operating model turns a main agent into an issue-planning orchestrator and
delegates one GitHub issue per isolated executor worktree and PR, with deterministic stop gating
and a human-only merge decision.

## Session continuity

Memhub is the source of truth at `.memhub/project.sqlite`. When present, read
`.memhub/rendered/PROJECT.md` at session start. Rendered files are generated and must not be edited
directly.

## Build, test, and validation

There is no application build. Validate the configuration surfaces instead:

- PowerShell gate tests: `Invoke-Pester tests/*.Tests.ps1`
- Plugin validation: run the installed `plugin-creator/scripts/validate_plugin.py` against
  `plugins/fable-sonnet-orchestrator-kit`
- Skill validation: run `skill-creator/scripts/quick_validate.py` for every bundled skill
- Codex configuration: `codex doctor` and a fresh-thread wiring probe after reinstalling the plugin

## Source layout

- `.claude/` is the Claude Code kit and remains supported.
- `.agents/plugins/marketplace.json` is the repo-local Codex marketplace; the plugin source is
  `plugins/fable-sonnet-orchestrator-kit/`.
- `.codex/agents/` contains the source TOMLs for Codex custom agents; the deployed user-scope
  copies live at `~/.codex/agents/`.
- `.codex/orch.on` and `.claude/orch.on` are separate, gitignored per-repo toggles.
- `tests/` covers the deterministic gate and Codex packaging/wiring.

## Working on this repository

Preserve behavioral parity across the Claude and Codex implementations unless the user explicitly
requests divergence. Port platform vocabulary, paths, models, and tool calls without changing the
issue → worktree → PR → review → human merge workflow. The deployed plugin is cached: editing this
checkout does not update the live Codex install until the cachebuster/reinstall flow is run. Copy
changed custom-agent TOMLs to `~/.codex/agents/` deliberately and verify the live copies.

Do not overwrite pre-existing user changes in `.gitignore`, `CLAUDE.md`, memhub files, or live
global configuration. Use surgical edits and keep live-config backups until verification passes.
