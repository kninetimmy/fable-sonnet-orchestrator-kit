# executor-stop-gate.ps1 — Claude Code Stop/SubagentStop hook for the sonnet-executor agent.
#
# Purely code-based PR gate (no LLM decision anywhere in this loop):
#   exit 0            -> allow the executor to end its turn
#   exit 2 + stderr   -> BLOCK the stop; stderr text is fed back into the live executor
#                        session as its next instruction
#
# Gate rules:
#   1. No PR opened and no "BLOCKED:" declaration  -> block once ("open a PR or declare BLOCKED").
#   2. PR MERGED or CLOSED                          -> allow.
#   3. Changes requested and no commit pushed since -> block, injecting EVERY unaddressed signal:
#      every "[ORCH-REVIEW] CHANGES-REQUESTED" marker comment AND every formal CHANGES_REQUESTED
#      review whose timestamp is newer than the last fix commit, concatenated in chronological
#      order — not just the single newest one, so a trickle of several review rounds posted
#      across multiple comments/reviews is never silently dropped from what gets injected.
#      "Changes requested" is EITHER a formal CHANGES_REQUESTED review (works when the reviewer
#      is a different GitHub account) OR a PR comment starting with "[ORCH-REVIEW]
#      CHANGES-REQUESTED" — required because all agents typically share one GitHub account and
#      GitHub forbids formal request-changes reviews on your own PR. If a fix commit lands after
#      the NEWEST such signal, the whole set counts as addressed (falls through to rule 4).
#   4. Anything else (approved / review pending, or the whole changes-requested set already
#      addressed by a newer commit) -> allow; the orchestrator is notified of the stop by the
#      harness task-notification and resumes the executor only if needed.
#
# Fail-open by design: any parse/network/gh failure allows the stop — this gate must never
# trap an agent because of tooling breakage.

$ErrorActionPreference = 'SilentlyContinue'
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'

try { $hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
if (-not $hookInput) { exit 0 }
# Harness compat (Claude Code 2.1.x): for SubagentStop, transcript_path is the PARENT session's
# transcript; the executor's own transcript is agent_transcript_path. Prefer the executor's.
$transcript = $hookInput.agent_transcript_path
if (-not $transcript) { $transcript = $hookInput.transcript_path }
if (-not $transcript -or -not (Test-Path $transcript)) { exit 0 }

# Scan the executor's transcript (tolerating the live writer's lock) for:
#  - the LAST GitHub PR URL it produced (its own PR), and
#  - a literal "BLOCKED:" declaration (the executor's documented escape hatch).
$prUrl = $null
$declaredBlocked = $false
$prRegex = 'https://github\.com/[\w.-]+/[\w.-]+/pull/\d+'
try {
    $fs = [System.IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
    $reader = New-Object System.IO.StreamReader($fs)
    while ($null -ne ($line = $reader.ReadLine())) {
        $found = [regex]::Matches($line, $prRegex)
        if ($found.Count -gt 0) { $prUrl = $found[$found.Count - 1].Value }
        if ($line -match 'BLOCKED:') { $declaredBlocked = $true }
    }
    $reader.Close(); $fs.Close()
} catch { exit 0 }

if (-not $prUrl) {
    if ($declaredBlocked) { exit 0 }
    # Only nudge once: if we already blocked this stop cycle and there is still no PR,
    # let it end — the orchestrator sees the result and decides.
    if ($hookInput.stop_hook_active -eq $true) { exit 0 }
    # Harness compat (Claude Code 2.1.x): SubagentStop exit-2 does NOT block; the supported
    # blocking mechanism is JSON {"decision":"block","reason":...} on stdout with exit 0.
    $reason = @"
STOP GATE: no pull request found for your work. You must either:
(a) push your branch and open a PR into main now:
    gh pr create --base main --title "<imperative scope> (#<issue>)" --body "Closes #<issue> ..."
    then include the PR URL in your final message; or
(b) if you are genuinely unable to proceed, flag the issue (blocked / needs-human-clarification),
    comment the exact blocker on the issue, and end your final message with a line starting with
    'BLOCKED: <reason>'.
"@
    [Console]::Out.WriteLine((@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress))
    exit 0
}

$pr = $null
try { $pr = gh pr view $prUrl --json state,reviews,comments,commits,url 2>$null | ConvertFrom-Json } catch { exit 0 }
if (-not $pr) { exit 0 }
if ($pr.state -eq 'MERGED' -or $pr.state -eq 'CLOSED') { exit 0 }

# All changes-requested signals: formal reviews (cross-account) OR [ORCH-REVIEW] marker comments
# (same-account orchestrator). Collect EVERY one (not just the newest) so a trickle of several
# review rounds is never silently dropped from what gets injected below.
$marker = '[ORCH-REVIEW] CHANGES-REQUESTED'
$signals = @()
foreach ($cr in ($pr.reviews | Where-Object { $_.state -eq 'CHANGES_REQUESTED' })) {
    try { $signals += [pscustomobject]@{ Time = [datetime]$cr.submittedAt; Body = $cr.body } } catch { }
}
foreach ($cm in ($pr.comments | Where-Object { $_.body -and $_.body.StartsWith($marker) })) {
    try { $signals += [pscustomobject]@{ Time = [datetime]$cm.createdAt; Body = $cm.body } } catch { }
}
if ($signals.Count -eq 0) { exit 0 }   # approved or review pending -> allow stop (parking)
$signals = @($signals | Sort-Object Time)
$newestSignalTime = $signals[-1].Time

# Addressed already? (any commit pushed after the NEWEST changes-requested signal — same
# threshold as before this change, now computed across the full collected set instead of a
# single tracked winner.)
$headCommit = $pr.commits | Select-Object -Last 1
$headTime = $null
if ($headCommit -and $headCommit.committedDate) {
    try { $headTime = [datetime]$headCommit.committedDate } catch { exit 0 }
}
if ($headTime -and $headTime -gt $newestSignalTime) { exit 0 }

# Unaddressed = every signal not already covered by that last fix commit (i.e. not older than
# it). With no head-commit timestamp to compare against, every collected signal is unaddressed.
$unaddressed = if ($headTime) { @($signals | Where-Object { $_.Time -ge $headTime }) } else { $signals }

# Unaddressed changes-requested feedback -> block and inject every unaddressed signal in full.
$number = $null; $owner = $null; $repo = $null
if ($prUrl -match 'github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)') {
    $owner = $Matches[1]; $repo = $Matches[2]; $number = $Matches[3]
}
$inlineText = ''
if ($owner) {
    try {
        $inline = gh api "repos/$owner/$repo/pulls/$number/comments" --paginate 2>$null | ConvertFrom-Json
        if ($inline) {
            $inlineText = ($inline | ForEach-Object { "- $($_.path):$($_.line ?? $_.original_line): $($_.body)" }) -join "`n"
        }
    } catch { }
}

$reviewText = ($unaddressed | ForEach-Object { "=== REVIEW ($($_.Time.ToString('u'))) ===`n$($_.Body)" }) -join "`n`n"

$msg = @"
STOP GATE: changes were requested on your PR $($pr.url) and you have not pushed a fix since that
review. Address EVERY point below in your worktree, run your targeted tests, push to the PR
branch, and reply on the PR with what you changed (gh pr comment $number --body "..."). Then
finish again. If a point is genuinely impossible or out of scope, say why in a PR comment and end
with 'BLOCKED: <reason>'.

$reviewText
"@
if ($inlineText) { $msg += "`n=== INLINE COMMENTS ===`n$inlineText" }

# Harness compat (Claude Code 2.1.x): block via JSON stdout, not exit 2 (see note above).
[Console]::Out.WriteLine((@{ decision = 'block'; reason = $msg } | ConvertTo-Json -Compress))
exit 0
