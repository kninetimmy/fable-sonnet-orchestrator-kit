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
