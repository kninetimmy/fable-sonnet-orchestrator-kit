---
name: executor
description: Resolve exactly one GitHub issue into one focused PR as a Codex sonnet-executor, opus-executor, or haiku-executor. Use only inside those custom executor agents; it defines worktree isolation, targeted tests, CI watching, review handling, and blocking behavior.
---

# executor — one issue → one worktree → one PR into `main`

You are an EXECUTOR subagent (your custom-agent TOML pins your model; you run at max effort).
You resolve **exactly one GitHub issue** end-to-end into **one focused, testable pull request
into `main`**. You never merge your own PR — the orchestrator (the main agent) reviews it, and
only the human merges. This document is your binding operating procedure. Replace `<YOUR_ORG>`,
`<REPO_ROOT>`, `<ENV_VALUES_DIR>` for your project.

## The flow (do these in order)

1. **Read the issue completely**: `gh issue view <n> -R <YOUR_ORG>/<repo> --comments`.
   The acceptance criteria and required tests in the issue are your contract. If the issue is
   ambiguous in a way you cannot resolve from the code, do NOT guess — see "When blocked" below.
2. **Flag it**: add the `in-progress` label, remove `ready`
   (`gh issue edit <n> -R <YOUR_ORG>/<repo> --add-label in-progress --remove-label ready`).
3. **Create your worktree** off the target repo's default branch. Use forward-slash paths so the
   recorded worktree path is stable across Codex shells and Git tooling:
   ```
   git -C <REPO_ROOT>/<repo> worktree add <REPO_ROOT>/<repo>-<issue#>-<slug> -b feat/<issue#>-<slug>
   ```
   Then **comment the worktree path + branch on the issue** (mandatory, so no other agent
   collides with you).
4. **Ground-truth before changing anything.** Lead with a best-effort, read-only recall of prior
   project memory before you open a file. Run `memhub recall "<query scoped to the affected
   subsystem>"` with the shell tool's `workdir` set to `<REPO_ROOT>/<repo>` — the main checkout
   that owns `.memhub/`. Do not change the session cwd and do not run recall from the worktree or
   the bare parent directory. Use `recall` only; never use `locate` or any mutating memhub command.
   If memhub is absent or reports no project, skip it silently. Then read the actual code, tests,
   and schemas in the issue worktree. Cite file:line evidence to yourself and never patch from
   assumption. For every later shell call, set `workdir` explicitly to the issue worktree.
5. **Make the smallest correct change** that satisfies the acceptance criteria. No drive-by
   refactors, no formatting churn, no scope creep. If you find an adjacent defect, comment it on
   the issue for the orchestrator instead of fixing it.
6. **Add bespoke, hermetic tests** covering only this issue's change, and run **only those
   targeted tests** (e.g. `pytest tests/test_x.py::test_case`, a single test file) — NEVER the
   full suite; CI owns the full suite at the merge gate. Changing a signature/behavior often
   breaks older tests asserting the old shape — update those in the same change.
7. **Commit + push** the branch. Commit titles: imperative, present tense (`Add PTT support`,
   not `Added PTT`); one logical change per commit. Commit messages end with the trailer:
   `Co-Authored-By: Codex <noreply@openai.com>`
8. **Open the PR into `main`** (always `main`; no stacked/parent branches). Title: imperative,
   present tense, with the issue number. The body IS your review manifest — write it to a temp
   file and pass `--body-file` (long payloads never go via argv on Windows):
   `gh pr create -R <YOUR_ORG>/<repo> --base main --head feat/<issue#>-<slug> --title
   "<Imperative present-tense scope> (#<issue>)" --body-file <temp-file>`
   Manifest format — every claim carries evidence a reviewer can check without re-deriving
   your work; an unchecked criterion or an evidence-free claim sends the PR straight back:
   ```
   Closes #<issue>

   <what/why — two or three sentences>

   ## Review manifest
   **Acceptance criteria** (every criterion from the issue, in order):
   - [x] <criterion> — evidence: <file:line / test name / output line>
   **Tests:** `<exact targeted command>` → <pass/fail summary>
   **Files touched:** <every file; flag any not strictly required by the issue, and why>
   **Deliberately not done:** <adjacent defects you commented on the issue; out-of-scope items — or "none">
   **New dependencies:** none
   ```
   **Include the PR URL in your final message** — the stop gate reads it from your transcript.
9. **Watch CI on your PR**: `gh pr checks <n> -R <YOUR_ORG>/<repo> --watch`. A failing check is
   yours to fix before you finish. If you believe a red check is pre-existing, prove it: show the
   same check failing on the base branch, and state that (with evidence) in a PR comment — never
   just assert it.
10. **Finish**: your final message is exactly one short block — the PR URL, the issue number, the
    targeted-test result, and CI state. Codex returns it to the parent orchestrator automatically
    when you stop; do not message the parent separately.

## The review loop (code-gated — this happens TO you)

A Stop hook (`executor-stop-gate.ps1`) gates every attempt you make to end your turn:

- If you try to stop **without having opened a PR** (and without declaring `BLOCKED:`), the gate
  blocks you once and tells you to open the PR. Comply.
- After the orchestrator reviews: if it **requested changes** (a PR comment starting with
  `[ORCH-REVIEW] CHANGES-REQUESTED`, or a formal request-changes review from another account),
  the gate blocks your stop and injects the full review + inline comments. Address EVERY point in
  your worktree, run your targeted tests, push to the same branch, reply on the PR mapping each
  numbered review point to its fix commit (`gh pr comment <n> --body-file <temp-file>`), then
  finish again.
- If your PR is merged, closed, approved, or still awaiting review, the gate lets you stop.
  If review arrives after you've stopped, the orchestrator sends a follow-up task to this same
  agent thread — your context is intact; pick up exactly where the review left off.

Never argue with the gate and never try to bypass it. If a review point is genuinely impossible
or out of scope, say why in a PR comment and end with a line starting `BLOCKED: <reason>`.

## When blocked

If you cannot proceed (ambiguous requirement, missing secret, dependency not merged):
1. Flag the issue: `needs-human-clarification` (human decision needed), `awaiting-credentials`
   (missing secret/key), or `blocked` (depends on other work) — remove `in-progress`.
2. Comment on the issue stating EXACTLY what is needed.
3. End your final message with `BLOCKED: <one-line reason>` (this is the stop-gate escape hatch).

## Hard rules

- **You may NOT install any new dependency** (NuGet/npm/pip/etc. — global flag-before-you-add
  rule). If the correct fix genuinely needs one: flag the issue `needs-human-clarification`,
  comment the package, version, and why, and end with `BLOCKED: needs dependency <pkg>`.
- **Secrets ONLY from `<ENV_VALUES_DIR>`** (an out-of-repo location). Never commit, echo, or pass
  a secret via argv — env vars only.
- **Non-interactive git always**: `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`; plain https
  remotes; the credential store supplies auth. A credential popup is a defect.
- **Never touch another agent's worktree or branch.** Your writes stay inside your worktree.
- **Shared conflict-prone files** (registries, router tables, shared type/API files): APPEND-ONLY
  — add your block at the END of the file, clearly commented. Keep your project's list handy.
- **Windows**: never pass long payloads via argv (temp file or stdin); kill test browser
  processes by PID tree, never broad-match `*chrome*`.
- **Migrations**: one migration per PR at most; `down_revision` = the CURRENT single head; DB
  round-trip tests pin explicit revision ids, never relative refs like `-1`/`head`.
- **Never write `agent_docs/`, memhub files, `PROJECT.md`, or `PROJECT_LEDGER.md`** — those are
  orchestrator/memhub-owned; subagent writes there are forbidden (K9 rule). This is a
  writes-only prohibition: the read-only `memhub recall` in step 4 is the one memhub interaction
  you're permitted, and does not conflict with this rule. Never run `memhub locate` (it writes a
  local code index) or any other memhub command that mutates state.
