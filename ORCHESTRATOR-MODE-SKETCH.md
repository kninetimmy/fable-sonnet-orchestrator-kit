# Orchestrator Mode — Finalized Sketch (design → plan → implement)

**Status:** Approved design sketch, ready to be turned into a plan and implemented.
**Written:** 2026-07-02, from a design session adapting this repo (`fable-sonnet-orchestrator-kit`)
to my personal workflow. A fresh session should be able to implement from this document alone.

---

## 1. Context — what this is and why

This repo is a drop-in Claude Code operating model: the main agent becomes an **orchestrator**
that decomposes intent into GitHub issues and fans out **executor subagents** (one per issue,
each in its own git worktree, each producing one focused PR into `main`), with a **code-based
PowerShell Stop hook** (`.claude/hooks/executor-stop-gate.ps1`) that enforces the hand-offs:
an executor cannot end its turn without a PR URL or an explicit `BLOCKED:` declaration, and a
`[ORCH-REVIEW] CHANGES-REQUESTED` PR comment blocks its stop and injects the review so it fixes
it immediately.

The kit was written for **Fable** in the orchestrator seat. Fable API access ends for me this
week; the adaptation targets **Opus 4.8 as orchestrator** and **Sonnet 5 as the default executor**
(selectively — not always), running on **subscription** (quota-weighted, not per-token billed).
Nothing in the kit is actually Fable-specific; "Fable" just means "strong model in the main seat."

**The adaptation must adhere to all rules in my global `~/.claude/CLAUDE.md`** (merge gates,
subagent dispatch policy, plan-before-large-changes, flag-before-adding-dependencies, security
rules, memhub/K9 compatibility). The toggle changes *who does the work* (issue fan-out vs. main
thread), never the rules — the same global rules apply in both modes.

## 2. Decisions already made (locked — do not re-litigate)

1. **Install scope: user-scope (`~/.claude/`) with a per-repo toggle flag.** One copy of the
   agents/skills/hook to maintain; any repo can enable it; repos without the flag are untouched.
2. **Parallel-dispatch reconciliation: toggle = standing approval.** One carve-out line is added
   to the global CLAUDE.md Subagent Dispatch Policy (edited in the global file, per that policy's
   own single-source-of-truth rule). Exact text in §7.
3. **Models:** orchestrator = whatever the main session runs (Opus 4.8 intended);
   `sonnet-executor` pinned `claude-sonnet-5`; `opus-executor` pinned `claude-opus-4-8`;
   `issue-triage` pinned `claude-sonnet-5`. All executors `effort: max`.
4. **No auto-merge, ever.** The orchestrator is sole *reviewer*; the human is sole *merger*.
   "Merging is the approval signal" from the original kit is replaced by a ready-to-merge report
   + human confirmation (global rule: "Merge to main only after I confirm").
5. **Memory: memhub owns it.** The kit's `handoff` skill is **dropped entirely** — `/wrap-up`,
   PROJECT.md, PROJECT_LEDGER.md already serve as rolling memory. Two competing memory artifacts
   is how both go stale.
6. **Two human gates, autonomy between them:** a **plan gate** before any issue is created and a
   **merge gate** per PR. Everything between (dispatch, executor work, review loop, fix cycles)
   runs autonomously.
7. **Sketch is final as presented** — implement it; don't redesign. Open implementation details
   (not design questions) are listed in §10.

## 3. Target file tree

```
~/.claude/
  agents/
    sonnet-executor.md        # pinned claude-sonnet-5, effort max — default worker
    opus-executor.md          # pinned claude-opus-4-8, effort max — tier:opus issues only
    issue-triage.md           # pinned claude-sonnet-5 — GitHub-issue clerk
  hooks/
    executor-stop-gate.ps1    # copied VERBATIM from this repo's .claude/hooks/
  skills/
    orchestrator/SKILL.md     # adapted operating model (the big rewrite — see §5)
    executor/SKILL.md         # ONE shared executor procedure, preloaded by BOTH executor agents
    issue-triage/SKILL.md     # near-verbatim from this repo
    orch/SKILL.md             # the toggle: /orch on | off | status (~30 lines)
  settings.json               # + one conditional SessionStart hook (merge into existing file)

<any repo>/.claude/
  orch.on                     # empty flag file, gitignored — presence = orchestrator mode ON
```

Source material: this repo's `.claude/` folder. `README.md` documents the original design.
Note the original targets Sonnet **4.6** (`claude-sonnet-4-6`) — every pin gets updated.

## 4. The toggle (`/orch` skill)

- **`/orch on`** — create `.claude/orch.on` in the current repo (add to `.gitignore` if not
  ignored), then adopt the orchestrator operating model **immediately** (invoking the skill loads
  it into context, so it takes effect mid-session, not just next session).
- **`/orch off`** — delete the flag; explicitly revert: "orchestrator mode off; resume the
  traditional workflow; all global CLAUDE.md rules unchanged." In-flight executors finish their
  current PR and park (the stop gate's "awaiting review → allow" state); nothing new dispatched.
- **`/orch status`** — report flag state + anything in flight (executor-owned open PRs, live
  worktrees).

**Session persistence** — one `SessionStart` hook in user-scope `~/.claude/settings.json`:

```
if "$CLAUDE_PROJECT_DIR/.claude/orch.on" exists:
    emit contents of ~/.claude/skills/orchestrator/SKILL.md   # session boots as orchestrator
else:
    emit nothing                                              # inert; zero context cost
```

Pattern reference: this repo's `.claude/settings.json` has the unconditional version (pwsh
`Get-Content -Raw` of the skill file). Add the `Test-Path` conditional and the home-dir path.
Windows note: the hook command string is not expanded by pwsh itself — resolve the home path
inside the pwsh command (`$env:USERPROFILE`), e.g.
`pwsh -NoProfile -Command "if (Test-Path \"$env:CLAUDE_PROJECT_DIR/.claude/orch.on\") { Get-Content -Raw \"$env:USERPROFILE/.claude/skills/orchestrator/SKILL.md\" }"`.

## 5. The operating model — adaptation deltas vs. this repo's `fable-orchestrator` skill

Start from `.claude/skills/fable-orchestrator/SKILL.md` and apply:

1. **Insert a plan gate before §1 (issue creation).** The orchestrator restates the request
   (global "prompt refinement" rule), decomposes it into the issue list — titles, model tier per
   issue, dependencies, dispatch waves — and presents it to the human **before creating anything
   on GitHub**. Approval covers the plan and starts the fan-out. (Satisfies "plan before large
   changes.")
2. **Rewrite §4 ("sole reviewer + merger") → sole reviewer, human merger.** Keep the full review
   discipline (read the whole diff via `gh pr diff`, walk acceptance criteria one by one, verify
   tests are real/bespoke/targeted, verify any "pre-existing" CI red also fails on the base
   branch). Keep the changes-requested loop via the `[ORCH-REVIEW] CHANGES-REQUESTED` marker
   comment + SendMessage resume. When a PR passes review and CI is green, present a
   **ready-to-merge report** (PR link, what/why, CI state, review notes) and WAIT. Merge only on
   human confirmation, then do the kit's cleanup: confirm issue auto-closed, comment merge result
   on the issue, remove the executor's worktree + prune, fast-forward local.
3. **Add model tiering to the issue taxonomy.** At issue creation assign exactly one tier label:
   `tier:sonnet` (default — standard implementation, clear-symptom debugging, multi-file
   refactors) or `tier:opus` (ambiguous debugging, architecture-adjacent, wrong-call-cascades
   work). Dispatch maps label → agent def (`sonnet-executor` / `opus-executor`). Haiku-tier work
   gets **no executor** — sub-30-seconds-of-main-thread work stays in the main thread per the
   dispatch policy. Tiers are visible/overridable at the plan gate.
4. **Concurrency:** ≤3–4 executors in parallel (kit's own stability limit), pre-approved while
   the flag is on (§7 carve-out). Keep the kit's serialization rules (conflict-prone files,
   one DB migration in flight at a time).
5. **Replace every `handoff.md` reference with memhub.** Orchestrator runs `/wrap-up` at
   milestones (memhub's own approval gates intact). Executors NEVER touch `agent_docs/`, memhub
   files, or PROJECT.md (K9 rule already forbids subagent writes there).
6. **PR/commit conventions:** titles imperative present tense (`Add PTT support (#14)`, not
   `feat: ...` — adjust the kit's `<type>: <scope>` template), PR bodies explain what/why,
   atomic commits, squash-merge + delete branch, standard Claude co-author trailer.
7. **Keep:** issues-are-the-todo-list, the full status/type/area flag taxonomy, the
   `issue-triage` clerk pattern, `needs-human-clarification` flow (questions the human must
   answer get flagged + surfaced; never silently block), secrets only in an out-of-repo dir,
   non-interactive git everywhere.

## 6. The executor — adaptation deltas vs. this repo's `sonnet-executor` skill

One shared `executor/SKILL.md` preloaded by BOTH executor agent defs (so the procedure can't
drift between tiers). Start from `.claude/skills/sonnet-executor/SKILL.md` and apply:

1. **CI watching (global git rule 5):** after pushing, watch the PR's checks; fix failures
   before finishing. A red check believed pre-existing must be shown failing on the base branch
   too, stated in the PR.
2. **New dependencies (global "flag before you add"):** executors may NOT install any new package
   (NuGet/npm/pip/etc.). Need one → flag the issue `needs-human-clarification`, comment
   package/version/why, end with `BLOCKED:`. The orchestrator surfaces it to the human.
3. **Keep everything else:** read issue → flag `in-progress` → forward-slash worktree → comment
   worktree+branch on the issue → ground-truth the code before changing → smallest correct
   change → bespoke targeted tests only (never the full suite) → push → PR with `Closes #N` +
   test evidence → final message is data (PR URL, issue #, test result, CI state).
4. **Agent defs** (`sonnet-executor.md`, `opus-executor.md`): copy the pattern from this repo's
   `.claude/agents/sonnet-executor.md` — update the model pin, point `skills:` at the shared
   `executor` skill, and point the Stop-hook path at `~/.claude/hooks/executor-stop-gate.ps1`
   (home-dir resolution caveat as in §4; `$CLAUDE_PROJECT_DIR/.claude/hooks/...` no longer
   applies since the hook lives user-scope). `opus-executor.md` description must say
   "dispatch only for tier:opus issues."
5. **`issue-triage.md` / its skill:** near-verbatim; update model pin to `claude-sonnet-5`.
   (Optional later: haiku for pure label ops — not now.)
6. **`executor-stop-gate.ps1`: copy VERBATIM.** It is model-agnostic, fail-open, and its
   allow/block rules already fit the human-merge-gate flow ("approved / review pending → allow"
   is the parking state while a PR awaits the human's merge word). Zero changes.

## 7. Global CLAUDE.md edit (exact text)

Add under **"Subagent Dispatch Policy"** in `~/.claude/CLAUDE.md`:

> **Orchestrator-mode carve-out:** while a repo's `.claude/orch.on` flag is set (via `/orch on`),
> parallel dispatch of up to 3–4 executor subagents is pre-approved as part of enabling the mode.
> `/orch off` restores the ask-first rule. All other dispatch-policy rules apply unchanged.

This is the ONLY global-rules change. Everything else in the adaptation conforms to the existing
rules as written.

## 8. Live-file edit protocol — `~/.claude/settings.json` and `~/.claude/CLAUDE.md`

Implementation touches exactly two files that are LIVE and load-bearing for **every** session on
this machine: `settings.json` (existing hooks, permissions, config) and `CLAUDE.md` (the global
rules). A careless overwrite breaks all sessions, not just this project. This procedure is
mandatory for BOTH files:

1. **Show the exact diff at the plan gate.** The implementation plan must contain the precise
   proposed change to each file — the exact SessionStart hook JSON to insert, and the exact
   carve-out lines (§7) with the anchor text they go under — for approval BEFORE anything is
   written. "I'll add a hook" is not a plan; the literal text is.
2. **Read the full current file first.** Never edit from an assumed shape — the real files may
   contain hooks/permissions/sections this sketch doesn't know about.
3. **Back up before editing:** copy each to `<file>.bak-<yyyymmdd-hhmm>` alongside the original.
   (If `~/.claude` happens to be a git repo, a pre-edit commit serves instead — check, don't
   assume either way.)
4. **Surgical edits only (Edit tool, anchored on existing unique text) — never Write/regenerate
   either file.**
   - `settings.json`: make the smallest structural addition that fits what's already there —
     append the new entry to an existing `hooks.SessionStart` array; else add a `SessionStart`
     key to the existing `hooks` object; else add a `hooks` object. Preserve every other key and
     the file's existing formatting/ordering; do not re-serialize or reformat. Do not touch
     `settings.local.json`.
   - `CLAUDE.md`: insert ONLY the §7 carve-out blockquote inside the existing "Subagent Dispatch
     Policy" section, anchored on that section's current text. Zero other line changes anywhere
     in the file.
5. **Validate after editing:**
   - `settings.json` still parses: `Get-Content -Raw ~/.claude/settings.json | ConvertFrom-Json`.
   - Diff each file against its backup (`git diff --no-index <bak> <file>` works outside a repo)
     and confirm the ONLY delta is the approved insertion.
6. **Functional check:** start a session in a repo WITHOUT `orch.on` → no injection and no
   hook/settings warnings at startup; in a repo WITH the flag → orchestrator skill injected.
   Any startup error about settings or hooks → restore the backup FIRST, diagnose second.
7. **Keep the backups until all §9 verification passes**, then report they can be removed.
   If anything goes sideways at any point: restore from backup, report what happened, and stop —
   do not iterate on a broken live file.

## 9. Verification steps (do these before calling it done)

1. **Model-pin inheritance test (the #1 gotcha, per this repo's README):** some Claude Code
   setups make subagents inherit the session model instead of honoring `model:` frontmatter.
   Dispatch one throwaway `sonnet-executor` from an Opus session and confirm it actually runs
   Sonnet 5. If it inherits, pass the model explicitly on every dispatch and note that in the
   orchestrator skill. On subscription, silent inheritance = every "cheap" executor burning
   Opus-rate quota.
2. **Toggle round-trip:** `/orch on` in a sandbox repo → flag exists + gitignored + role adopted
   mid-session; new session in that repo boots as orchestrator (SessionStart injection); session
   in a repo WITHOUT the flag gets zero injection; `/orch off` → flag gone, role reverted.
3. **Stop-gate dry run:** in a sandbox repo with a scratch issue, run one executor end-to-end:
   PR opened → orchestrator posts `[ORCH-REVIEW] CHANGES-REQUESTED` comment → executor's stop is
   blocked and review injected → fix pushed → parked → human merge word → merge + cleanup
   (issue closed, worktree removed, local fast-forwarded).
4. **Live-file edit safety:** the `settings.json` and `CLAUDE.md` edits were performed per the
   §8 protocol end-to-end — plan-gate diff approved, backups taken, surgical edits only, parse
   check passed, diff-vs-backup shows only the approved insertions, functional check green.

## 10. Open implementation details (fine to resolve while implementing; not design changes)

- Exact quoting/escaping of the two pwsh hook command strings on Windows (SessionStart
  conditional; Stop-hook home-dir path). Test both fire correctly.
- Where `/orch on` inserts the `.gitignore` entry if the repo has none.
- `/orch status`'s exact `gh`/`git worktree list` queries.
- Whether `effort: max` on `claude-sonnet-5` is accepted as-is by the current harness version.

## 11. Sanity notes for the implementing session

- This repo (the clone you're sitting in) is the **source material**, not the install target.
  The install target is `~/.claude/`. Don't modify this repo except by explicit request.
- Placeholders in the source skills (`<YOUR_ORG>`, `<REPO_ROOT>`, `<ENV_VALUES_DIR>`) stay as
  placeholders in the user-scope copies too — they're per-project values the orchestrator fills
  from context, since the user-scope install serves many repos. `<YOUR_ORG>` for my repos is
  `NickalasLight`.
- Global CLAUDE.md rules ride on every session, including executor subagent sessions — the
  executor skill restates the critical ones (secrets, deps, no scope creep) because they're
  load-bearing, not because subagents don't see them.
- Quota reality on subscription: the Opus orchestrator seat is long-lived and reads full diffs —
  that's where quota goes. Sonnet executors are the savings. `tier:opus` dispatches are the
  expensive exception; the plan gate is where I keep an eye on that.
