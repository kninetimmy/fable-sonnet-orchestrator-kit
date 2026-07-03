# Observability

What you can — and can't — see about executor cost and behavior once an
orchestrator-mode session ends, and the opt-in workaround this project uses
when it needs real per-executor numbers. This doc is scoped to cost/token
observability only; see [`README.md`](../README.md)'s "How it works"
section for the gate's general PR-loop behavior.

## Executor token cost is unauditable post-hoc

Claude Code (2.1.x, as run in this project) does not persist a background
executor subagent's full transcript once its turn ends. Only the
orchestrator's own main-thread transcript survives a session. For each
executor, the harness retains just a final result/output artifact — and
because the [`executor` skill](../.claude/skills/executor/SKILL.md) instructs
every executor to keep its final message to one short, data-only block (PR
URL, issue number, targeted-test result, CI state — step 10 of the flow),
that surviving artifact is frequently empty and, even when it isn't, never
carries token or cost information.

Practical consequence: **after the fact, there is no way to reconstruct how
many tokens an individual executor spent.** The only number you get for
free is whatever the orchestrator's own thread consumed for that session —
the coordinator plus however many executors it fanned out to is, by
default, a black box once those subagent turns end.

## Opt-in capture: instrumenting the SubagentStop gate

The one place an executor's transcript is still guaranteed to be on disk is
*while its `SubagentStop` hook is running* — the gate script
([`.claude/hooks/executor-stop-gate.ps1`](../.claude/hooks/executor-stop-gate.ps1))
already reads that transcript live (via `agent_transcript_path`) to scan for
the executor's PR URL and any `BLOCKED:` declaration. That same moment is
the last chance to snapshot the transcript before the harness cleans it up.

This project validated the approach with a small, isolated, flag-gated
block added to the gate script immediately after the transcript path is
resolved:

```powershell
# --- TEST INSTRUMENTATION (flag-gated, reversible) ---------------------------------------------
# Executor token-metrics capture. Claude Code discards subagent transcripts after the run, but this
# hook can read them live. When `.claude/exec-metrics.on` exists, snapshot the executor's transcript
# (plus a diagnostic line) into `.claude/exec-metrics/` so real per-executor token usage can be
# computed offline. Fully isolated: any failure here MUST NOT change the gate's exit behaviour.
# TEARDOWN: delete this block, `.claude/exec-metrics.on`, and `.claude/exec-metrics/`.
try {
    $metricsFlag = Join-Path $PSScriptRoot '..\exec-metrics.on'
    if (Test-Path $metricsFlag) {
        $metricsDir = Join-Path $PSScriptRoot '..\exec-metrics'
        if (-not (Test-Path $metricsDir)) { New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null }
        $leaf = Split-Path $transcript -Leaf
        # Diagnostic line: proves WHICH transcript we captured (executor vs parent) and payload shape.
        $agentPresent  = [bool]$hookInput.agent_transcript_path
        $parentPresent = [bool]$hookInput.transcript_path
        $fields = ($hookInput.PSObject.Properties.Name) -join ','
        Add-Content -LiteralPath (Join-Path $metricsDir '_capture-log.txt') `
            -Value "$((Get-Date).ToString('u')) leaf=$leaf agent_present=$agentPresent parent_present=$parentPresent stop_active=$($hookInput.stop_hook_active) fields=[$fields]"
        # Snapshot, share-aware (live writer holds the lock). Overwrite by leaf so repeated
        # SubagentStop fires converge on the complete transcript for that executor.
        $srcFs = [System.IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
        $dstFs = [System.IO.File]::Open((Join-Path $metricsDir $leaf), 'Create', 'Write', 'None')
        $srcFs.CopyTo($dstFs)
        $dstFs.Close(); $srcFs.Close()
    }
} catch { }
# --- END TEST INSTRUMENTATION ------------------------------------------------------------------
```

**What it does:**
- Gated on the presence of `.claude/exec-metrics.on` (an empty flag file) —
  when absent, the block is a single `Test-Path` call and nothing else.
- Copies the live transcript into `.claude/exec-metrics/<same filename>`,
  opening the source with `Read`/`ReadWrite` share mode so it doesn't
  collide with the harness's own writer holding the file open.
- Overwrites by filename, so if an executor's stop cycles more than once
  (e.g. it gets blocked and resumed), later captures converge on the most
  complete transcript for that executor.
- Appends one line to `.claude/exec-metrics/_capture-log.txt` recording
  which field supplied the transcript path (`agent_transcript_path` vs. the
  parent session's `transcript_path`) and the raw field list on the hook
  payload — enough to confirm you captured the *executor's* transcript, not
  the orchestrator's.
- Captured transcripts are ordinary JSONL session transcripts; feed them to
  whatever token-accounting you already use for a main session to compute a
  real per-executor input/output/cache token breakdown, offline.

**Enable / disable:**
- Enable: create an empty `.claude/exec-metrics.on` file in the repo whose
  gate you want instrumented (per-checkout, not global — the flag lives
  under that repo's own `.claude/`).
- Disable: delete `.claude/exec-metrics.on`. The very next `SubagentStop`
  skips the block — no restart needed.
- Full teardown: also delete `.claude/exec-metrics/` and remove the block
  itself from the gate script (see the `TEARDOWN` line in its header
  comment above).
- Both `.claude/exec-metrics.on` and `.claude/exec-metrics/` are local-only
  and may contain full agent reasoning — they should be added to
  `.gitignore` and never committed.

**Fail-open and reversible:** the whole block is wrapped in its own
`try { } catch { }` with nothing rethrown, so any capture failure (locked
file, missing directory, permissions) is swallowed and can never change the
gate's actual allow/block decision — the instrumentation is fully isolated
from the gate's real job. It is also strictly additive: removing the block,
the flag file, and the capture directory returns the gate to its
unmodified behavior with no other side effects.

**Status:** this is an opt-in technique for when you specifically need
per-executor cost data — it is not part of the committed
`executor-stop-gate.ps1` and the kit does not enable it by default. Add the
block above at the location shown when you want to audit costs, flip on
`.claude/exec-metrics.on` for the session(s) you're measuring, and tear both
down when you're done.

## When orchestrator mode pays off (rule of thumb)

Orchestrator mode is not free — weigh it against a single thread doing the
same work directly:

- **Costs more total tokens.** A fan-out is the coordinator's own long-lived
  thread (which reads every PR's full diff during review) *plus* N executor
  sessions, each paying its own fresh-context and tool-call overhead.
  Summed across all of them, that's more raw tokens than one thread doing
  the same work serially.
- **Keeps the main thread lean.** In exchange, the orchestrator's own
  context never ingests any executor's file reads, edit iterations, or test
  output — only the final PR and review. Rule of thumb: roughly half the
  context tax lands on the main thread compared to doing the work directly;
  the rest is absorbed by executors' disposable contexts, which are
  discarded when they stop (see above).
- **Parallelizes.** Independent issues run concurrently — up to the kit's
  own stability ceiling of 3-4 executors at once — so wall-clock time drops
  even though total token spend rises.

**Reach for orchestrator mode when** the work is parallelizable (multiple
independent, `ready` issues) and doing it in one thread would balloon that
thread's context past what you'd want in a single session. **Stay
single-thread when** the task is focused and sequential — one file, one
clear fix, a quick question — where filing an issue, spinning up a
worktree, and reviewing a PR is pure coordination overhead with no
parallelism to pay for it.
