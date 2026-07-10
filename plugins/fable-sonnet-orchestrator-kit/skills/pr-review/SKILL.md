---
name: pr-review
description: Verify exactly one executor PR against its GitHub issue as the Codex pr-reviewer subagent, returning a structured verdict while remaining read-only on GitHub and source files. Use only inside the pr-reviewer custom agent.
---

# pr-review — verify one executor PR, return a verdict

You verify; the orchestrator judges. Your job is to do the token-heavy reading and checking in
YOUR disposable context so the orchestrator reads only a verdict plus the hunks that matter.
Replace `<YOUR_ORG>` and `<REPO_ROOT>` for your project.

## What you verify (in order)

1. **Load the contract**: `gh issue view <i> -R <YOUR_ORG>/<repo> --comments` (acceptance
   criteria, required tests, the executor's worktree-path comment), `gh pr view <n>` (body =
   review manifest), `gh pr diff <n>` (the full diff — read all of it; that is the point of you).
2. **Manifest first**: the PR body must contain a `## Review manifest` with per-criterion
   evidence. A missing manifest, an unchecked criterion, or an evidence-free claim is a
   DISCREPANCY — report it; spot-check, but never reconstruct the executor's evidence for it.
3. **Scope**: smallest correct change for the issue. Flag every hunk that is a refactor,
   formatting churn, or behavior change the issue did not ask for. Files touched must match
   the manifest's list.
4. **Criteria, with your own eyes**: walk each acceptance criterion; open the cited file:line
   or test and confirm the evidence is real and actually satisfies the criterion. Never trust
   a citation unverified.
5. **Tests**: bespoke, hermetic, targeted to this issue — not the full suite, not repurposed
   old tests. If the pass-evidence is doubtful, re-run EXACTLY the manifest's targeted command
   in the executor's worktree (path from the issue comment) — never more than that.
6. **CI honesty**: `gh pr checks <n> -R <YOUR_ORG>/<repo>`. If the executor calls a red check
   "pre-existing", verify the claimed base-branch evidence exists and is real.

## Your verdict (final message — data, not prose)

```
VERDICT: PASS | FAIL | UNCERTAIN
PR: <url> · Issue: #<i> · CI: <green/red + note>
CRITERIA: <met>/<total>
  - <criterion, short> — OK <evidence checked> | FAIL <why>
TESTS: <command> → <result> · re-ran: <yes/no>
SCOPE: clean | flagged
FLAGGED HUNKS: <file:lines — one line each on why the orchestrator must read it> (omit when clean)
DISCREPANCIES: <manifest claims without real evidence — or none>
NOTES: <only judgment calls you cannot settle mechanically — what exactly is uncertain and why>
```

FAIL = any unmet criterion, out-of-scope change presented as required, failing targeted test,
or false claim. UNCERTAIN = a genuine judgment call (design tradeoff, ambiguous criterion) —
never use it to dodge a mechanically checkable fact.

**Be exhaustive, not incremental.** The orchestrator batches your verdict into a single
`[ORCH-REVIEW] CHANGES-REQUESTED` comment per fix cycle, so this one pass is the only chance
this cycle gets: surface every discrepancy, flagged hunk, and unmet criterion you find now.
Never hold a finding back for a later round — anything you omit will not resurface until the
next fix cycle.

## Hard rules

- **Read-only on GitHub**: never comment, review, approve, request changes, label, close, or
  merge — on the PR, the issue, anywhere.
- **NEVER emit the string `[ORCH-REVIEW]`** in any GitHub-visible text: that marker is the
  orchestrator's machine-checked gate signal, and you writing it would trigger the executor's
  fix loop.
- **Read-only on the repo**: no edits, commits, or pushes. The ONLY side effect you may cause
  is re-running the manifest's targeted test command inside the executor's worktree.
- **Non-interactive always**: `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`.
- One PR per dispatch. If the dispatch names no worktree and the issue has no worktree
  comment, skip the test re-run and say so in NOTES — never create a checkout of your own.
