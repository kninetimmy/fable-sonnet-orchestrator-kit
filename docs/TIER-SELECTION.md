# Tier selection

How the orchestrator decides which model tier resolves an issue, why the
boundaries sit where they do, and the rules that keep a cheaper tier from
costing *more* than a dearer one. This doc is the rubric of record; the
enforceable one-liners live in
[`.claude/skills/fable-orchestrator/SKILL.md`](../.claude/skills/fable-orchestrator/SKILL.md)
§0–§1, and each tier maps to a model-pinned agent under
[`.claude/agents/`](../.claude/agents/).

## Where the decision is made

Tier is assigned by the **orchestrator at the plan gate** (SKILL §0), one
per issue, as a judgment call, and is **human-overridable at that gate**.
Nothing re-decides tier at runtime except the escalation rule below. The
label maps 1:1 to a model-pinned executor at dispatch — so the tier written
on the issue *is* the model that does the work.

## The two axes hidden in "tier"

Tier selection is really two independent questions, and conflating them is
the historical trap:

- **Axis A — gate or no gate.** Does this change warrant an issue + worktree
  + PR + review at all? The test is *"is there a reviewable diff worth the
  audit trail and isolation?"* — **not** clock time. Work with no reviewable
  surface stays in the main thread with no issue and no executor.
- **Axis B — which model,** *given* it is an issue. How much reasoning does a
  correct, first-pass change demand: `tier:haiku` / `tier:sonnet` /
  `tier:opus`.

The word "haiku" names an Axis-B *capability* tier. It does **not** name the
no-executor bucket — that bucket is "trivial / main-thread" and is an Axis-A
decision. (Earlier phrasings of the rubric used "haiku-tier" to mean
"too small for an issue"; that conflation is retired.)

## The rubric

| Tier | Route here when | The test |
|---|---|---|
| **trivial** (no executor) | No reviewable diff worth a PR — do it inline in the main thread | Axis A: nothing to review in isolation |
| **`tier:haiku`** | The diff is **mechanically determined** by the issue — zero design latitude | *Could two competent engineers disagree on the shape of the fix? If no → haiku.* Renames across files, add a config key, version bump, apply a documented codemod, add a test mirroring an existing one. |
| **`tier:sonnet`** *(default)* | Any real implementation *choice* exists: standard features, clear-symptom debugging, multi-file refactors | The default. `tier:haiku` is an **explicit downgrade the orchestrator must justify**, never the default. |
| **`tier:opus`** | Ambiguous debugging, architecture-adjacent, or work where a wrong call cascades | Deep reasoning; a wrong first pass is costly to unwind |

**The haiku gate in one line:** *if the executor has to choose between two
reasonable implementations, it is at least `tier:sonnet`.*

## Why the haiku boundary is conservative

The review loop **amplifies under-tiering**. From the n=1 cost baseline (see
[`OBSERVABILITY.md`](./OBSERVABILITY.md) and the README cost section): each
executor run is ~40k output / ~4M cache-read, and *every fix cycle re-runs
the executor and re-dispatches `pr-reviewer`* (~94k output in the dogfood
datapoint). So a `tier:haiku` executor that gets a change wrong and bounces
twice can cost **more** than a `tier:sonnet` executor that lands it on the
first pass — and it burns a review round-trip each time.

The asymmetry is the whole point:

- **Over-tiering** (sonnet where haiku would do) is *merely wasteful* — more
  tokens, correct result.
- **Under-tiering** (haiku where sonnet was needed) is *expensive and slow* —
  the gate turns one weak pass into a chain of executor + reviewer cycles.

Therefore route to `tier:haiku` **only when first-pass correctness is
near-certain**. When unsure, the default (`tier:sonnet`) is the safe call.

## Two mechanism rules that make the tier safe

1. **Escalate on bounce; do not haiku-retry.** A `tier:haiku` PR that draws
   an `[ORCH-REVIEW] CHANGES-REQUESTED` is *evidence the work exceeded the
   mechanical bar*. The fix cycle **re-dispatches the issue as
   `sonnet-executor`** rather than resuming the haiku agent. Mechanical note:
   the model is pinned in agent frontmatter, so "escalate" means a fresh
   dispatch at the higher tier — **not** a `SendMessage` resume of the
   original agent. The orchestrator owns this branch of the SKILL §3 loop.
2. **The plan gate states the *reason* for a `tier:haiku` tag.** Surfacing
   *why* a downgrade is safe lets the human override catch an over-optimistic
   call — the cheap failure to prevent before the expensive one happens.

## Deliberately left alone

- **`pr-reviewer` stays pinned `claude-sonnet-5` even for `tier:haiku` PRs.**
  Verification is harder than the mechanical change it checks, and
  mis-verification is the expensive failure mode. Do not tier the reviewer
  down to match the executor.
- **`tier:sonnet` remains the default.** Adding a third tier does not change
  which tier an unmarked issue gets.
