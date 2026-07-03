# Kit vs. user-scope install — divergence audit

This document records how this repo's shipped `.claude/` tree diverges from the **deployed
user-scope orchestrator install** at `~/.claude` (`C:\Users\Kninetimmy\.claude`). It closes the
known gap tracked in the project state: the kit is *source material* and the deployed instance has
evolved separately.

- **Audit date:** 2026-07-02
- **Repo base:** `main` @ `2502a52`
- **Method:** read-only comparison of both trees. Text compared EOL-normalized
  (`diff --strip-trailing-cr`); line endings audited separately (CR byte counts). **No file
  outside this repo was modified.**

## Governing principle (who is canonical)

Per `CLAUDE.md` and `ORCHESTRATOR-MODE-SKETCH.md`, **this repo is the source material** and the
user-scope tree is a *deployed adaptation of it*. So:

- The **kit is canonical** for the shared operating procedure (skills, agent defs, the gate).
- `ORCHESTRATOR-MODE-SKETCH.md` §5–§6 enumerate the **intended, permanent deltas** the install is
  supposed to apply (rename, user-scope paths, the `/orch` flag-gate). Those are *by design*, not
  drift — no port is owed in either direction.
- A divergence is **actionable** only when it is *not* one of those intended deltas — i.e. real
  drift where one side has fallen behind the other.

### Kind legend

| Kind | Meaning |
|------|---------|
| **In sync** | Content-identical (modulo EOL); no action. |
| **By design** | An intended, permanent adaptation per the sketch; no port owed. |
| **Drift** | Unintended lag — one side is stale; a port is owed. **Actionable.** |
| **Local / out-of-scope** | Machine-local or non-kit file; not a shipped divergence. |

## TL;DR — the only actionable items

1. **`agents/sonnet-executor.md` is stale in the kit (Drift).** The user-scope copy carries
   `tier:sonnet` routing in its description plus "watch the PR's CI checks" and "never install new
   dependencies" in its prompt; the kit's copy is missing all three. The kit's own
   `opus-executor.md` *already* has this language, so the kit's `sonnet-executor.md` is the odd one
   out. **Port user-scope → kit.**
2. **Orchestrator-skill clarifications could be back-ported (optional).** The user-scope
   `orchestrator` skill added a few reusable clarifications (explicit model pins, the "changes
   *who* does the work, never the rules" framing, the dispatch-policy carve-out note) on top of the
   sketch's prescribed adaptations. Folding the *repo-agnostic* ones back into the kit's
   `fable-orchestrator` skill keeps the source teaching-complete. **Optional port user-scope → kit.**

Everything else is either already in sync, an intended by-design delta, or an expected machine-local
artifact.

---

## 1. Skills

Repo ships `skills/{executor, fable-orchestrator, issue-triage}`. User-scope has
`skills/{executor, issue-triage, orch, orchestrator}`.

| Item | Repo `.claude/` | User-scope `~/.claude/` | Kind | Canonical · port |
|------|-----------------|-------------------------|------|------------------|
| Orchestrator skill — name & path | `skills/fable-orchestrator/SKILL.md` | `skills/orchestrator/SKILL.md` | **By design** (renamed + rescoped project→user, sketch §5) | Canonical: each for its scope · Port: none |
| Orchestrator skill — description | "Auto-injected **every session** by the SessionStart hook." | "Injected by the SessionStart hook **when the repo's `.claude/orch.on` flag is set**; toggled with `/orch`." | **By design** (each accurately describes its own trigger) | Canonical: each for its scope · Port: none |
| Orchestrator skill — body | Base operating model. | Same model **plus**: "changes *who* does the work, never the rules" paragraph + `/orch off` revert; explicit model pins (`claude-sonnet-5` / `claude-opus-4-8`); dispatch-policy carve-out note; "no `handoff.md`" wording. | Mostly **By design** (sketch §5 deltas); a few added clarifications are **Drift**-adjacent | Canonical: kit for the core model, user-scope for the added clarifications · Port: optional user-scope → kit for the repo-agnostic clarifications |
| `orch` toggle skill | *absent* (kit ships no `orch` skill) | `skills/orch/SKILL.md` (36 lines): `/orch on\|off\|status`, manages the `.claude/orch.on` flag | **By design** (the toggle only exists in the multi-repo install; the kit repo is always-orchestrator) | Canonical: user-scope · Port: optional user-scope → kit only if the kit wants to document the toggle |
| `executor` shared skill | `skills/executor/SKILL.md` | `skills/executor/SKILL.md` | **In sync** — content-identical (this shared file is the intended anti-drift mechanism, sketch §6) | Canonical: kit · Port: none |
| `issue-triage` skill | `skills/issue-triage/SKILL.md` | `skills/issue-triage/SKILL.md` | **In sync** — content-identical | Canonical: kit · Port: none |

## 2. Agents

Repo ships `agents/{issue-triage, opus-executor, sonnet-executor}`. User-scope has those three
**plus** eight general-purpose agents that are not part of the kit (see §5).

| Item | Repo `.claude/` | User-scope `~/.claude/` | Kind | Canonical · port |
|------|-----------------|-------------------------|------|------------------|
| `sonnet-executor.md` | Description lacks tier routing; prompt lacks "watch the PR's CI checks" **and** "never install new dependencies". | Description adds "dispatch for `tier:sonnet` issues (standard implementation, clear-symptom debugging, multi-file refactors)"; prompt adds CI-watch step **and** the no-new-dependencies constraint. | **Drift** — kit copy is stale vs. sketch §6.1–§6.2 and vs. its own `opus-executor.md` | Canonical: user-scope · **Port: user-scope → kit** |
| `opus-executor.md` | model `claude-opus-4-8`; carries CI-watch + no-new-deps language | identical | **In sync** — content-identical | Canonical: kit · Port: none |
| `issue-triage.md` | model pin, tool scope, prompt | identical | **In sync** — content-identical | Canonical: kit · Port: none |
| Model pins (both executors) | `sonnet-executor: claude-sonnet-5`, `opus-executor: claude-opus-4-8` | identical | **In sync** | Canonical: kit · Port: none |

## 3. Stop gate

`hooks/executor-stop-gate.ps1` in both trees.

| Item | Repo `.claude/` | User-scope `~/.claude/` | Kind | Canonical · port |
|------|-----------------|-------------------------|------|------------------|
| Gate logic (transcript scan, PR/BLOCKED detection, allow/block rules) | identical | identical | **In sync** — byte-identical modulo the block below (sketch §6.6 mandates a verbatim copy) | Canonical: kit · Port: none |
| `# TEST INSTRUMENTATION` block (28 lines, flag-gated on `.claude/exec-metrics.on`) | present (transient) | absent | **Local / out-of-scope** — transient token-metrics capture; ignored per issue #14; fully isolated (cannot change the gate's exit behaviour) | Canonical: n/a · Port: none — delete at instrumentation teardown to restore exact parity |

## 4. Settings wiring — `settings.json`

The kit ships a deliberately **minimal, hooks-only** `settings.json` (so it can serve as source
material without clobbering a user's real machine config). The user-scope `settings.json` is a full
machine config that *includes* the same two hooks plus a lot of unrelated machine settings.

| Item | Repo `.claude/` | User-scope `~/.claude/` | Kind | Canonical · port |
|------|-----------------|-------------------------|------|------------------|
| SessionStart — trigger | **Unconditional** (injects every session) | **Gated**: `if (Test-Path "$CLAUDE_PROJECT_DIR/.claude/orch.on") { ... }` | **By design** — kit repo is always-orchestrator; the install is opt-in per repo via `/orch` | Canonical: each for its scope · Port: none |
| SessionStart — injected skill | `$CLAUDE_PROJECT_DIR/.claude/skills/**fable-orchestrator**/SKILL.md` | `$USERPROFILE/.claude/skills/**orchestrator**/SKILL.md` | **By design** — project-scope vs. user-scope path + the rename | Canonical: each for its scope · Port: none |
| SubagentStop — matcher | `sonnet-executor\|opus-executor` | `sonnet-executor\|opus-executor` | **In sync** — identical | Canonical: kit · Port: none |
| SubagentStop — gate path | `$CLAUDE_PROJECT_DIR/.claude/hooks/executor-stop-gate.ps1` | `$USERPROFILE/.claude/hooks/executor-stop-gate.ps1` | **By design** — project-scope vs. user-scope path | Canonical: each for its scope · Port: none |
| Everything else in user-scope `settings.json` (`permissions` allowlist, `model: opus[1m]`, `UserPromptSubmit` statusline hook, `statusLine`, `enabledPlugins`, `extraKnownMarketplaces`, `effortLevel`, `autoUpdatesChannel`, `tui`, …) | *absent* (kit stays minimal) | present | **Local / out-of-scope** — real-machine config, not part of the kit surface | Canonical: user-scope (machine config) · Port: none |

---

## 5. User-scope-only agents (context, not kit divergences)

The user-scope `~/.claude/agents/` also contains eight general-purpose subagents that are **not
part of this kit** and therefore are not divergences of any kit file:
`build-diagnoser`, `claude-md-curator`, `diff-reviewer`, `doc-researcher`, `git-archaeologist`,
`implementer`, `log-digger`, `test-runner`. They are listed here only so a reader diffing the two
`agents/` directories isn't surprised by the extra files. **No port owed** — out of kit scope.

## 6. Expected-local artifacts (explicitly NOT divergences)

Per issue #14, the following are machine-local / gitignored and are **expected** to differ or exist
on only one side. They are not shipped divergences:

| Artifact | Status | Note |
|----------|--------|------|
| `.claude/orch.on` | gitignored (`.gitignore:8`) | Machine-local mode flag. Present in the repo checkout on disk, but the kit's `settings.json` injects unconditionally and ignores it, so it is inert in-repo. |
| `.claude/exec-metrics.on`, `.claude/exec-metrics/` | gitignored (`.gitignore:10–11`) | Machine-local. The `.on` flag is what activates the transient gate instrumentation block (§3). |
| `.memhub/` | gitignored (`.gitignore:15`) | Machine-local memory store (source of truth for session continuity); rendered views are also gitignored. |
| `.claude/settings.local.json` | gitignored (global `**/.claude/settings.local.json`) | Machine-local on **both** sides (repo ~72 lines, user-scope ~23 lines). Neither is tracked, so the difference is not a shipped divergence. |
| Gate `# TEST INSTRUMENTATION` block | transient, flag-gated | Ignored for this comparison per issue #14 (§3). |

## 7. Cross-cutting note — line endings (low priority)

Line endings are **inconsistent** across the user-scope copies and were normalized out of every
content comparison above. Measured CR byte counts (repo → user-scope):

| File | Repo | User-scope |
|------|------|------------|
| `skills/executor/SKILL.md` | CRLF | **LF** |
| `skills/issue-triage/SKILL.md` | CRLF | CRLF |
| `agents/issue-triage.md` | CRLF | **LF** |
| `agents/opus-executor.md` | CRLF | **LF** |
| `agents/sonnet-executor.md` | CRLF | **LF** |
| `hooks/executor-stop-gate.ps1` | CRLF | CRLF |
| `settings.json` | CRLF | **LF** |

The kit ships CRLF throughout; some user-scope files are LF while others stayed CRLF. This mix is
almost certainly an **install/edit artifact** (some files copied preserving CRLF, others rewritten
LF by an editor), not a meaningful drift. Low priority. If it ever matters, normalize the
user-scope copies (or add a `.gitattributes` to the kit to pin EOL); it does not affect behaviour.

---

## Summary

| Category | In sync | By design | Drift (actionable) | Local / out-of-scope |
|----------|:-------:|:---------:|:------------------:|:--------------------:|
| Skills | `executor`, `issue-triage` | rename/path, description, most of body, `orch` toggle | — (optional body back-port) | — |
| Agents | `opus-executor`, `issue-triage`, model pins | — | **`sonnet-executor.md`** | 8 non-kit agents |
| Stop gate | gate logic | — | — | `# TEST INSTRUMENTATION` block |
| Settings | SubagentStop matcher | SessionStart gate/path, gate path | — | permissions/model/statusline/plugins/… |

**Net:** the kit and the deployed install are in sync on everything that matters except one stale
agent def (`sonnet-executor.md`, port user-scope → kit) and an optional clarification back-port of
the orchestrator skill. All other differences are intended by-design adaptations or expected
machine-local artifacts.
