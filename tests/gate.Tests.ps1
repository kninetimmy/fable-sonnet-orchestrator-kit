#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    gate.Tests.ps1 — Pester tests for the executor stop gate's OFFLINE decision branches.

    PESTER VERSION ASSUMPTION: Pester v5 (>= 5.0). The `#Requires` above enforces
    this — running under the Windows-bundled Pester 3.x fails loudly with a clear
    "missing module" error instead of cryptic v3-vs-v5 syntax failures. This file
    uses the Pester v5
    API surface exclusively — top-level BeforeAll/AfterAll, the `Should -Operator`
    assertion syntax, and `-Skip` on `It`. It will NOT parse/run correctly under
    Pester 3.x (the Windows-bundled default), so run it explicitly under v5:

        Import-Module Pester -MinimumVersion 5.0   # if v5 is not already loaded
        Invoke-Pester tests/gate.Tests.ps1

    Also assumes PowerShell 7+ (pwsh) on PATH: both the gate under test and these
    harness invocations target pwsh (the gate uses PS7-only syntax elsewhere).

    SCOPE (issue #11): exercises ONLY the branches that resolve before the gate's
    first `gh` network call — the transcript scan and the no-PR decision — plus
    one fail-open branch. Fully offline: every test writes an inline temp-file
    transcript fixture (never a real transcript) and pipes synthetic hook-input
    JSON to the gate on stdin. The gate script
    (.claude/hooks/executor-stop-gate.ps1) is treated as READ-ONLY.

    EXTENDED SCOPE (issue #29): the branches that DO depend on a `gh pr view` /
    `gh api` response — multi-signal collection, chronological concatenation,
    and the "addressed already?" threshold — are reached with a second, still
    fully offline technique: PowerShell resolves a same-named FUNCTION ahead of
    any external command (about_Command_Precedence), so a `function gh { ... }`
    defined in the same scope as a dot-sourced copy of the gate script fully
    replaces the real `gh` binary for that one child process. Zero real
    network/`gh` calls; the gate script is still treated as READ-ONLY. See
    `Invoke-GateWithGhStub` below.

    CONTRACT NOTE: in every offline branch the gate exits 0. A BLOCK is signalled
    by a {"decision":"block",...} JSON object on stdout (Claude Code 2.1.x
    SubagentStop protocol), NOT by a nonzero exit code. So these tests discriminate
    block-vs-allow on stdout content and assert exit 0 throughout. The temporary
    `# --- TEST INSTRUMENTATION` exec-metrics block in the gate is out of scope
    and is never activated here (its `.claude/exec-metrics.on` flag is absent).
#>

BeforeAll {
    # Resolve the gate relative to this test file (worktree-safe) at run time.
    $script:GatePath = (Resolve-Path (Join-Path $PSScriptRoot '..' '.claude' 'hooks' 'executor-stop-gate.ps1')).Path

    # One throwaway directory for all fixtures; removed wholesale in AfterAll.
    $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gate-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $script:FixtureDir -Force | Out-Null

    # Substring that uniquely marks a BLOCK decision in the gate's stdout JSON.
    $script:BlockMarker = '"decision":"block"'

    # Write $Lines to a fresh temp transcript fixture; return its absolute path.
    function New-TranscriptFixture {
        param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Lines)
        $path = Join-Path $script:FixtureDir ("transcript-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $path -Value $Lines -Encoding UTF8
        return $path
    }

    # Run the gate as a child pwsh, feeding hook-input JSON on stdin (as Claude
    # Code does). Returns @{ StdOut = <string>; ExitCode = <int> }.
    function Invoke-Gate {
        param([Parameter(Mandatory)] [hashtable] $HookInput)
        $json = $HookInput | ConvertTo-Json -Compress
        $out  = $json | pwsh -NoProfile -ExecutionPolicy Bypass -File $script:GatePath 2>$null
        return @{
            StdOut   = ([string]($out | Out-String))
            ExitCode = $LASTEXITCODE
        }
    }

    # --- issue #29: `gh`-stub harness for the branches that depend on a `gh pr view` / `gh api`
    # response (multi-signal collection, chronological concatenation, "addressed already?").
    # PowerShell resolves a same-named FUNCTION ahead of any external command
    # (about_Command_Precedence), so a `function gh { ... }` defined in the same scope as a
    # dot-sourced copy of the gate script fully replaces the `gh` binary for that child process —
    # still fully offline, zero real network/`gh` calls, gate script still treated as READ-ONLY.
    $script:GhStubWrapperPath = Join-Path $script:FixtureDir 'gh-stub-wrapper.ps1'
    @'
function gh {
    if ($args.Count -ge 2 -and $args[0] -eq "pr" -and $args[1] -eq "view") { Write-Output $env:GATE_TEST_GH_PR_JSON; return }
    if ($args.Count -ge 1 -and $args[0] -eq "api") { Write-Output $env:GATE_TEST_GH_INLINE_JSON; return }
}
. $env:GATE_TEST_GATE_PATH
'@ | Set-Content -LiteralPath $script:GhStubWrapperPath -Encoding UTF8

    # Run the gate as a child pwsh with `gh` shadowed by the stub above. $PrJson is the canned
    # `gh pr view --json ...` payload; $InlineJson is the canned `gh api .../comments` payload
    # (an empty JSON array unless a test needs inline comments too). Same return shape as
    # Invoke-Gate above.
    function Invoke-GateWithGhStub {
        param(
            [Parameter(Mandatory)] [hashtable] $HookInput,
            [Parameter(Mandatory)] [string] $PrJson,
            [string] $InlineJson = '[]'
        )
        $json = $HookInput | ConvertTo-Json -Compress
        $prevGate = $env:GATE_TEST_GATE_PATH
        $prevPr = $env:GATE_TEST_GH_PR_JSON
        $prevInline = $env:GATE_TEST_GH_INLINE_JSON
        $env:GATE_TEST_GATE_PATH = $script:GatePath
        $env:GATE_TEST_GH_PR_JSON = $PrJson
        $env:GATE_TEST_GH_INLINE_JSON = $InlineJson
        try {
            $out = $json | pwsh -NoProfile -ExecutionPolicy Bypass -File $script:GhStubWrapperPath 2>$null
            return @{
                StdOut   = ([string]($out | Out-String))
                ExitCode = $LASTEXITCODE
            }
        } finally {
            $env:GATE_TEST_GATE_PATH = $prevGate
            $env:GATE_TEST_GH_PR_JSON = $prevPr
            $env:GATE_TEST_GH_INLINE_JSON = $prevInline
        }
    }
}

AfterAll {
    if ($script:FixtureDir -and (Test-Path -LiteralPath $script:FixtureDir)) {
        Remove-Item -LiteralPath $script:FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'executor-stop-gate — offline decision branches' {

    Context 'no PR URL in the transcript' {

        # Issue #11, case 1.
        It 'blocks once (no-PR nudge) when stop_hook_active is unset' {
            $t = New-TranscriptFixture @(
                '{"type":"assistant","text":"working the change, no PR link produced yet"}'
                'ran the targeted tests locally, all green'
            )
            $r = Invoke-Gate @{ agent_transcript_path = $t }

            $r.ExitCode | Should -Be 0
            $r.StdOut.Trim() | Should -Not -BeNullOrEmpty
            $decision = $r.StdOut | ConvertFrom-Json
            $decision.decision | Should -Be 'block'
            $decision.reason   | Should -Match 'no pull request found'
        }

        # Issue #11, case 2.
        It 'allows when the transcript declares BLOCKED:' {
            $t = New-TranscriptFixture @(
                'investigated the failing path'
                'BLOCKED: upstream credentials are unavailable in this environment'
            )
            $r = Invoke-Gate @{ agent_transcript_path = $t }

            $r.ExitCode | Should -Be 0
            $r.StdOut | Should -Not -BeLike "*$script:BlockMarker*"
            $r.StdOut.Trim() | Should -BeNullOrEmpty
        }

        # Issue #11, case 3 (single-nudge rule).
        It 'allows on the second stop cycle when stop_hook_active = true' {
            $t = New-TranscriptFixture @(
                'still working; no PR link yet on this second stop cycle'
            )
            $r = Invoke-Gate @{ agent_transcript_path = $t; stop_hook_active = $true }

            $r.ExitCode | Should -Be 0
            $r.StdOut | Should -Not -BeLike "*$script:BlockMarker*"
            $r.StdOut.Trim() | Should -BeNullOrEmpty
        }
    }

    Context 'transcript path resolution (fail-open)' {

        # Issue #11, case 4 (nonexistent path).
        It 'allows when the transcript path does not exist' {
            $missing = Join-Path $script:FixtureDir ("never-created-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
            $r = Invoke-Gate @{ agent_transcript_path = $missing }

            $r.ExitCode | Should -Be 0
            $r.StdOut | Should -Not -BeLike "*$script:BlockMarker*"
            $r.StdOut.Trim() | Should -BeNullOrEmpty
        }

        # Issue #11, case 4 (missing path field entirely — the other fail-open leg).
        It 'allows when no transcript path field is present at all' {
            $r = Invoke-Gate @{ stop_hook_active = $false }

            $r.ExitCode | Should -Be 0
            $r.StdOut | Should -Not -BeLike "*$script:BlockMarker*"
            $r.StdOut.Trim() | Should -BeNullOrEmpty
        }
    }

    Context 'PR URL present but gh call fails (fail-open after the network hop)' {

        # Issue #11, case 5 (stretch) — intentionally SKIPPED.
        It 'allows when gh is unreachable or unauthorized' -Skip {
            # This branch (gate lines 100-101: `gh pr view <url>` -> $null -> exit 0) only runs
            # AFTER a real `gh` invocation. Forcing that call to fail DETERMINISTICALLY and
            # OFFLINE would require shadowing the `gh` executable on PATH with a failing stub, or
            # mutating the child process PATH — both are environment-fragile and step outside the
            # "pipe synthetic JSON, assert stdout" offline harness this file establishes. Exercising
            # it against a real (even bogus) URL would hit the network, which issue #11 forbids.
            # Per the issue's constraint ("if a branch is untestable without refactoring the gate,
            # add a -Skip'ped test"), this is left documented rather than injecting a fake gh or
            # touching the read-only gate. The fail-open contract here (exit 0, no block JSON) is
            # identical to the covered nonexistent-transcript case above.
        }
    }
}

Describe 'executor-stop-gate — SubagentStop matcher configuration (issue #26)' {

    Context 'settings.json SubagentStop matcher' {

        # Regression guard: the gate is wired via SubagentStop's `matcher` regex, so any
        # executor type missing from this string stops completely ungated (silently, since
        # the hook simply never fires for it) — see README "The SubagentStop hook doesn't
        # seem to fire". This pins all three current executor tiers so a future narrowing
        # (e.g. dropping haiku-executor again) fails loudly here instead.
        It 'includes all three executor types (sonnet, opus, haiku)' {
            $settingsPath = (Resolve-Path (Join-Path $PSScriptRoot '..' '.claude' 'settings.json')).Path
            $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
            $matcher  = $settings.hooks.SubagentStop[0].matcher

            $matcher | Should -Match 'sonnet-executor'
            $matcher | Should -Match 'opus-executor'
            $matcher | Should -Match 'haiku-executor'
        }
    }
}

Describe 'executor-stop-gate — multi-signal concatenation (issue #29)' {

    Context 'multiple unaddressed changes-requested signals' {

        # Issue #29: two [ORCH-REVIEW] marker comments AND one formal CHANGES_REQUESTED review,
        # listed out of chronological order in the canned `gh pr view` payload (LATE before
        # EARLY), with no commits at all (nothing pushed since any of them) -> every one of the
        # three must appear in the injected block message, in TIME order (not payload/insertion
        # order, and not grouped by signal kind), and the pre-existing inline-comment injection
        # must still follow them.
        It 'concatenates every unaddressed signal in chronological order, with inline comments still appended' {
            $prJson = @'
{
  "state": "OPEN",
  "url": "https://github.com/acme/widgets/pull/42",
  "reviews": [
    { "state": "CHANGES_REQUESTED", "submittedAt": "2024-01-01T11:00:00Z", "body": "REVIEW-MID: fix the null check" }
  ],
  "comments": [
    { "body": "[ORCH-REVIEW] CHANGES-REQUESTED\nREVIEW-LATE: missing test for edge case", "createdAt": "2024-01-01T12:00:00Z" },
    { "body": "[ORCH-REVIEW] CHANGES-REQUESTED\nREVIEW-EARLY: typo in docstring", "createdAt": "2024-01-01T10:00:00Z" }
  ],
  "commits": []
}
'@
            $inlineJson = '[ { "path": "src/foo.ps1", "line": 10, "body": "nit: rename this variable" } ]'
            $t = New-TranscriptFixture @('opened https://github.com/acme/widgets/pull/42')

            $r = Invoke-GateWithGhStub -HookInput @{ agent_transcript_path = $t } -PrJson $prJson -InlineJson $inlineJson

            $r.ExitCode | Should -Be 0
            $decision = $r.StdOut | ConvertFrom-Json
            $decision.decision | Should -Be 'block'

            $reason = $decision.reason
            $reason | Should -Match 'REVIEW-EARLY: typo in docstring'
            $reason | Should -Match 'REVIEW-MID: fix the null check'
            $reason | Should -Match 'REVIEW-LATE: missing test for edge case'
            $reason | Should -Match 'nit: rename this variable'

            # Chronological order, independent of payload order (LATE is listed before EARLY in
            # the JSON above) and independent of signal kind (the formal review sorts between the
            # two marker comments purely by timestamp).
            $reason.IndexOf('REVIEW-EARLY') | Should -BeLessThan $reason.IndexOf('REVIEW-MID')
            $reason.IndexOf('REVIEW-MID')   | Should -BeLessThan $reason.IndexOf('REVIEW-LATE')
            $reason.IndexOf('REVIEW-LATE')  | Should -BeLessThan $reason.IndexOf('nit: rename this variable')
        }

        # Issue #29: a commit was pushed BETWEEN two of the three signals above (after
        # REVIEW-EARLY, before REVIEW-MID/REVIEW-LATE) -> REVIEW-EARLY is already addressed by
        # that commit and must be dropped from the injected message; REVIEW-MID and REVIEW-LATE
        # are still unaddressed and must both still appear.
        It 'drops signals older than the last fix commit while still injecting the ones after it' {
            $prJson = @'
{
  "state": "OPEN",
  "url": "https://github.com/acme/widgets/pull/42",
  "reviews": [
    { "state": "CHANGES_REQUESTED", "submittedAt": "2024-01-01T11:00:00Z", "body": "REVIEW-MID: fix the null check" }
  ],
  "comments": [
    { "body": "[ORCH-REVIEW] CHANGES-REQUESTED\nREVIEW-LATE: missing test for edge case", "createdAt": "2024-01-01T12:00:00Z" },
    { "body": "[ORCH-REVIEW] CHANGES-REQUESTED\nREVIEW-EARLY: typo in docstring", "createdAt": "2024-01-01T10:00:00Z" }
  ],
  "commits": [
    { "committedDate": "2024-01-01T10:30:00Z" }
  ]
}
'@
            $t = New-TranscriptFixture @('opened https://github.com/acme/widgets/pull/42')

            $r = Invoke-GateWithGhStub -HookInput @{ agent_transcript_path = $t } -PrJson $prJson

            $r.ExitCode | Should -Be 0
            $decision = $r.StdOut | ConvertFrom-Json
            $decision.decision | Should -Be 'block'
            $decision.reason | Should -Not -Match 'REVIEW-EARLY'
            $decision.reason | Should -Match 'REVIEW-MID: fix the null check'
            $decision.reason | Should -Match 'REVIEW-LATE: missing test for edge case'
        }
    }

    Context 'addressed set still allows (regression guard)' {

        # Issue #29's explicit "addressed set" requirement: same three-signal set as above, but
        # the fix commit landed AFTER the newest of them -> the whole set counts as addressed,
        # matching the pre-existing single-signal "addressed already?" allow-path (the gate must
        # not start blocking forever just because it now tracks more than one signal).
        It 'allows the stop when a fix commit is newer than the newest of several unaddressed signals' {
            $prJson = @'
{
  "state": "OPEN",
  "url": "https://github.com/acme/widgets/pull/42",
  "reviews": [
    { "state": "CHANGES_REQUESTED", "submittedAt": "2024-01-01T11:00:00Z", "body": "REVIEW-MID: fix the null check" }
  ],
  "comments": [
    { "body": "[ORCH-REVIEW] CHANGES-REQUESTED\nREVIEW-LATE: missing test for edge case", "createdAt": "2024-01-01T12:00:00Z" },
    { "body": "[ORCH-REVIEW] CHANGES-REQUESTED\nREVIEW-EARLY: typo in docstring", "createdAt": "2024-01-01T10:00:00Z" }
  ],
  "commits": [
    { "committedDate": "2024-01-01T13:00:00Z" }
  ]
}
'@
            $t = New-TranscriptFixture @('opened https://github.com/acme/widgets/pull/42')

            $r = Invoke-GateWithGhStub -HookInput @{ agent_transcript_path = $t } -PrJson $prJson

            $r.ExitCode | Should -Be 0
            $r.StdOut | Should -Not -BeLike "*$script:BlockMarker*"
            $r.StdOut.Trim() | Should -BeNullOrEmpty
        }
    }
}
