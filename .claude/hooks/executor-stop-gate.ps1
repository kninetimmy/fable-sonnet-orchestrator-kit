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
#   3. Changes requested and no commit pushed since -> block, injecting the full feedback so the
#      executor fixes it now. "Changes requested" is EITHER a formal CHANGES_REQUESTED review
#      (works when the reviewer is a different GitHub account) OR a PR comment starting with
#      "[ORCH-REVIEW] CHANGES-REQUESTED" — required because all agents typically share one
#      GitHub account and GitHub forbids formal request-changes reviews on your own PR.
#   4. Anything else (approved / review pending)    -> allow; the orchestrator is notified of the
#      stop by the harness task-notification and resumes the executor only if needed.
#
# Fail-open by design: any parse/network/gh failure allows the stop — this gate must never
# trap an agent because of tooling breakage.

$ErrorActionPreference = 'SilentlyContinue'
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'

try { $hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
if (-not $hookInput) { exit 0 }
$transcript = $hookInput.transcript_path
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
    [Console]::Error.WriteLine(@"
STOP GATE: no pull request found for your work. You must either:
(a) push your branch and open a PR into main now:
    gh pr create --base main --title "<type>: <scope> (#<issue>)" --body "Closes #<issue> ..."
    then include the PR URL in your final message; or
(b) if you are genuinely unable to proceed, flag the issue (blocked / needs-human-clarification),
    comment the exact blocker on the issue, and end your final message with a line starting with
    'BLOCKED: <reason>'.
"@)
    exit 2
}

$pr = $null
try { $pr = gh pr view $prUrl --json state,reviews,comments,commits,url 2>$null | ConvertFrom-Json } catch { exit 0 }
if (-not $pr) { exit 0 }
if ($pr.state -eq 'MERGED' -or $pr.state -eq 'CLOSED') { exit 0 }

# Latest changes-requested signal: formal review (cross-account) OR [ORCH-REVIEW] marker comment
# (same-account orchestrator). Keep whichever is newest.
$signalTime = $null
$signalBody = $null
$lastCr = $pr.reviews | Where-Object { $_.state -eq 'CHANGES_REQUESTED' } | Sort-Object submittedAt | Select-Object -Last 1
if ($lastCr) { $signalTime = [datetime]$lastCr.submittedAt; $signalBody = $lastCr.body }
$marker = '[ORCH-REVIEW] CHANGES-REQUESTED'
$lastMarker = $pr.comments | Where-Object { $_.body -and $_.body.StartsWith($marker) } | Sort-Object createdAt | Select-Object -Last 1
if ($lastMarker) {
    $markerTime = [datetime]$lastMarker.createdAt
    if (-not $signalTime -or $markerTime -gt $signalTime) { $signalTime = $markerTime; $signalBody = $lastMarker.body }
}
if (-not $signalTime) { exit 0 }   # approved or review pending -> allow stop (parking)

# Addressed already? (any commit pushed after the latest changes-requested signal)
$headCommit = $pr.commits | Select-Object -Last 1
if ($headCommit -and $headCommit.committedDate) {
    try { if ([datetime]$headCommit.committedDate -gt $signalTime) { exit 0 } } catch { exit 0 }
}

# Unaddressed changes-requested feedback -> block and inject it in full.
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

$msg = @"
STOP GATE: changes were requested on your PR $($pr.url) and you have not pushed a fix since that
review. Address EVERY point below in your worktree, run your targeted tests, push to the PR
branch, and reply on the PR with what you changed (gh pr comment $number --body "..."). Then
finish again. If a point is genuinely impossible or out of scope, say why in a PR comment and end
with 'BLOCKED: <reason>'.

=== REVIEW ($($signalTime.ToString('u'))) ===
$signalBody
"@
if ($inlineText) { $msg += "`n=== INLINE COMMENTS ===`n$inlineText" }

[Console]::Error.WriteLine($msg)
exit 2
