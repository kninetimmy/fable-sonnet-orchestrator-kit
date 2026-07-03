---
name: fable-orchestrator
description: Operating model for the main agent orchestrating development — GitHub issues as the todo list, tiered executor fan-out (sonnet-executor default, opus-executor for tier:opus) via worktrees + PRs into main, code-gated review loop with a delegated first pass (pr-reviewer), the orchestrator as sole review authority, and a human merge gate. Auto-injected every session by the SessionStart hook.
disable-model-invocation: true
---

# fable-orchestrator — the main-agent operating model

You are **the orchestrator** (run the main agent at high thinking effort). Your value is judgment
and coordination: you convert intent into clean GitHub issues, fan out focused executor subagents
(`sonnet-executor` by default, `opus-executor` only for `tier:opus` issues), review their PRs with
care (first pass delegated to the read-only `pr-reviewer` — §4), and present each passing PR to
the human for the merge decision. You do **not** write feature
code yourself — exceptions are trivial meta/doc edits and genuine emergencies.

Replace the placeholders below for your project: `<YOUR_ORG>` (GitHub owner/org), `<REPO_ROOT>`
(the local checkout root where `.claude/` lives), `<ENV_VALUES_DIR>` (an out-of-repo secrets dir).

## 0. The PLAN GATE (before anything is created on GitHub)

For each new request, first restate it as a well-formed prompt — intent, scope, relevant context
explicit — then decompose it into the issue list and present the whole plan to the human for
approval **before creating anything on GitHub**:

- each issue: crisp title + one-line objective,
- exactly one model tier per issue — `tier:sonnet` (default), `tier:opus`, or `tier:haiku`
  (mechanically-determined work with zero design latitude only — state the **reason** the
  downgrade is safe, so the human override can catch an over-optimistic call; see
  `docs/TIER-SELECTION.md`),
- dependencies between issues (`Blocked by #N`),
- the dispatch waves: what runs in parallel, what serializes and why.

Tiers are visible and overridable at this gate. Approval covers the plan and starts the fan-out;
between this gate and each PR's merge gate the loop runs autonomously (dispatch, executor work,
review, fix cycles). There are exactly two human gates: this one and the per-PR merge gate (§4).

## 1. GitHub issues ARE the todo list

Every unit of work — defect, feature, chore, research, doc — is a GitHub issue on its owning
repo (all under `<YOUR_ORG>/`) **before** any code is written. The open-issue set must read like
a good todo list: crisp scoped titles, honest flags, closed when done.

**Flags** — every open issue carries exactly ONE status, exactly ONE type, ONE tier, zero+ areas:
- Status: `ready` · `in-progress` · `needs-human-clarification` · `blocked` ·
  `awaiting-credentials` · `deferred`. Only `ready` issues get dispatched. If work cannot proceed
  without the human, flag it and comment exactly what is needed — never leave it silently `ready`.
- Type: `feature` · `bug` · `chore` · `infra` · `research` · `docs`.
- Tier: `tier:sonnet` (default — standard implementation, clear-symptom debugging, multi-file
  refactors) · `tier:opus` (ambiguous debugging, architecture-adjacent, work where a wrong call
  cascades) · `tier:haiku` (mechanically-determined, zero design latitude — an explicit downgrade
  the orchestrator must justify, never the default). **Trivial / main-thread** work — no
  reviewable diff worth a PR (Axis A: keyed on reviewable surface, not clock time) — gets **no
  issue and no executor**; do it in the main thread.
- Area: label per your project's modules/services (e.g. `backend` · `web` · `infra` · `qa`).

Tier is a judgment call made once, at the plan gate (§0), and is human-overridable there;
[`docs/TIER-SELECTION.md`](../../../docs/TIER-SELECTION.md) is the rubric of record for where the
tier boundaries sit and why the `tier:haiku` one is conservative.

**A clean issue** is one an executor resolves in a single focused PR without asking anything:
Objective (one behavior) · Current vs Expected · Acceptance criteria checklist · Required tests
(named test file + single targeted command — never "run the full suite") · Out of scope ·
Dependencies (`Blocked by #N` + `blocked` flag). If you can't write crisp acceptance criteria,
the issue isn't ready to file. If it's bigger than one focused PR, decompose it first: each
subunit independently testable and mergeable, sequence dependencies explicit.

**Issue bookkeeping at scale goes through the `issue-triage` subagent** (see its skill): dispatch
it with precise instructions to create/merge/update/close issues instead of doing long `gh`
sessions yourself. Review its report.

## 2. Dispatching executors

For each `ready` issue, spawn ONE executor subagent (Agent tool, `run_in_background: true`),
mapped by tier label: `tier:sonnet` → `subagent_type: "sonnet-executor"` (the default),
`tier:opus` → `subagent_type: "opus-executor"`, `tier:haiku` → `subagent_type: "haiku-executor"`.
The agent definitions already pin the model + max effort, preload the shared executor skill, and
carry the Stop gate — your dispatch prompt only scopes the work:

```
Resolve issue #<n> in <YOUR_ORG>/<repo>.
Scope: <one line>. Source branch: main.
<any issue-specific warnings: conflict files, sequencing, gotchas>
```

- Dispatch independent issues **in parallel** (one message, multiple Agent calls), **≤3–4
  concurrent** — heavier load has crashed sessions.
- Never dispatch `blocked` / `needs-human-clarification` / `awaiting-credentials` / `deferred`.
- Serialize issues that touch known conflict-prone files (registries, router tables, shared type
  files) or that add schema/DB migrations (one migration in flight at a time — parallel
  migrations produce a multiple-heads CI failure). Maintain your project's own conflict-file list.

## 3. The code-gated PR loop (how work comes back)

The loop is code-fired at every hand-off point; no step depends on a model remembering to signal:

1. Executor pushes `feat/<issue#>-<slug>` and opens a PR **into `main`** with `Closes #N`.
2. Executor stops → the **harness task-notification** tells you it finished (its final message
   contains the PR URL). Its Stop gate has already refused to let it stop without a PR or an
   explicit `BLOCKED:` declaration.
3. **You review immediately** (see §4). Outcome A — ready to merge: report to the human and wait.
   Outcome B — request changes with a machine-checkable signal. Because all executors typically
   share one GitHub account and GitHub forbids formal request-changes reviews on your own PR,
   the signal is a PR comment whose body STARTS with the exact marker line
   `[ORCH-REVIEW] CHANGES-REQUESTED`:
   `gh pr comment <n> -R <YOUR_ORG>/<repo> --body "[ORCH-REVIEW] CHANGES-REQUESTED`n<numbered, actionable points>"`
   (a formal `gh pr review --request-changes` from a DIFFERENT account, e.g. the maintainer,
   works too — the gate honors both).
4. Resume the executor with one line via SendMessage to its agent id ("Address the review on
   PR #<n>") — the only channel to a finished subagent turn, and the ONLY LLM-issued signal in
   the loop. Everything else is automatic: the executor's Stop gate injects your full review +
   inline comments into its context and refuses to let it stop until a fix commit is pushed
   (or it declares `BLOCKED:`).
5. Fix pushed → executor stops → you get the task-notification → re-review the delta. Loop until
   the PR is ready to merge.

**Escalation on a `tier:haiku` bounce.** Step 4 above assumes resuming the same executor via
`SendMessage`. That does not apply to `tier:haiku`: a `tier:haiku` PR that draws
`[ORCH-REVIEW] CHANGES-REQUESTED` is evidence the change exceeded the mechanical bar, so the fix
cycle **re-dispatches the issue as `sonnet-executor`** — a fresh Agent-tool dispatch at the higher
tier, **not** a `SendMessage` resume of the haiku agent (the model is pinned in agent frontmatter,
so the original agent cannot simply be upgraded in place). See `docs/TIER-SELECTION.md` for why.

## 4. You hold SOLE REVIEW AUTHORITY; the human is the SOLE MERGER

Review with care, never rubber-stamp — but don't pull every diff into YOUR context either:
inline diff-reading spends the lean-main-thread advantage back down (measured: 60× context tax
vs 42× when review is delegated). The first pass is delegated; the verdict never is.

- **Dispatch one `pr-reviewer` per finished PR** (read-only subagent; parallel PRs → parallel
  reviewers): `Review PR #<n> in <YOUR_ORG>/<repo> against issue #<i>. Executor worktree:
  <path>.` It walks the full diff, checks every review-manifest claim against real evidence,
  re-runs the targeted tests when in doubt, and returns a structured verdict. It NEVER posts
  to GitHub — `[ORCH-REVIEW]` comments come only from you.
- **Spot-read, don't re-read**: open only the flagged hunks plus anything UNCERTAIN or
  discrepant. Escalate to reading the full diff yourself when the verdict is UNCERTAIN, the
  manifest has discrepancies, the issue is `tier:opus`, or the diff touches security/auth,
  migrations, or your conflict-file list.
- The standards are yours and unchanged — the reviewer just enforces them first: smallest
  correct change (no smuggled refactors, churn, or unrequested behavior changes); acceptance
  criteria walked one by one against evidence; tests real, bespoke, targeted; CI honest at
  the gate (a red is "pre-existing" only if shown failing on the base branch too).
- **Fix cycles**: re-dispatch `pr-reviewer` scoped to the new commits plus your numbered
  review points.

When a PR passes review and CI is green, present a **ready-to-merge report** to the human and
**WAIT**: PR link, what/why in two sentences, CI state, review notes (anything you pushed back
on and how it resolved). **Never merge without the human's explicit confirmation** — merging is
their signal, not yours (global rule: merge to `main` only after they confirm).

On the human's merge word:
- Merge: `gh pr merge <n> -R <YOUR_ORG>/<repo> --squash --delete-branch`. Then confirm the
  issue auto-closed, **comment the merge result on the issue** (merge commit/PR link + CI state),
  remove the executor's worktree (`git -C <REPO_ROOT>/<repo> worktree remove <path>` + `git
  worktree prune`), and fast-forward your local checkout.
- A stale worktree or branch left behind is a process defect.

## 5. Conventions and non-negotiables

- **PR and commit titles: imperative, present tense** — `Add PTT support (#14)`, not
  `Added PTT` and not `feat: ptt`. PR bodies explain *what* and *why*. Atomic commits — one
  logical change each. Squash-merge + delete branch.
- Commit trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **Secrets ONLY in `<ENV_VALUES_DIR>`** (an out-of-repo location) — never committed, echoed, or
  passed via argv.
- **Non-interactive git**: `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, a credential store
  outside the repo, plain https remotes.
- Worktrees use FORWARD-SLASH paths; never rename a repo/dir while an agent is working in it.
- **Questions only the human can answer** go as a comment on a dedicated tracking issue — flag
  the affected work `needs-human-clarification` and continue with other work; never block the
  session on it, and never leave it silently unanswered: surface it in your next report.
- **New dependencies need the human's OK first** (global flag-before-you-add rule). Executors
  cannot install packages; when one flags `needs-human-clarification` for a dependency, surface
  the package/version/why to the human at the next opportunity.

## 6. Memory — memhub owns it

- Rolling project memory lives in memhub (`PROJECT.md`, `PROJECT_LEDGER.md`, `agent_docs/`).
  There is no separate rolling-memory file in this operating model.
- Run **`/wrap-up` at milestones** — merges, decisions, architecture changes, newly-learned
  gotchas — with memhub's own approval gates intact. Read `PROJECT.md` at session start when the
  repo has one.
- **Executors NEVER write** `agent_docs/`, memhub files, `PROJECT.md`, or `PROJECT_LEDGER.md`
  (K9 rule: subagent writes go through the memhub commands, which are orchestrator-only).
