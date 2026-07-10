#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:MarketplaceRoot = Join-Path $script:RepoRoot '.agents\plugins'
    $script:PluginRoot = Join-Path $script:RepoRoot 'plugins\fable-sonnet-orchestrator-kit'
    $script:CodexAgents = Join-Path $script:RepoRoot '.codex\agents'
    $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-port-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $script:FixtureDir -Force | Out-Null
}

AfterAll {
    if ($script:FixtureDir -and (Test-Path -LiteralPath $script:FixtureDir)) {
        Remove-Item -LiteralPath $script:FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Codex plugin packaging' {
    It 'has a valid repo-local marketplace entry for the plugin' {
        $marketplace = Get-Content -Raw -LiteralPath (Join-Path $script:MarketplaceRoot 'marketplace.json') | ConvertFrom-Json
        $entry = $marketplace.plugins | Where-Object { $_.name -eq 'fable-sonnet-orchestrator-kit' }

        $marketplace.name | Should -Be 'personal'
        $entry | Should -Not -BeNullOrEmpty
        $entry.source.source | Should -Be 'local'
        $entry.source.path | Should -Be './plugins/fable-sonnet-orchestrator-kit'
        $entry.policy.installation | Should -Be 'AVAILABLE'
        $entry.policy.authentication | Should -Be 'ON_INSTALL'
    }

    It 'declares the skill bundle and relies on default hook discovery' {
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $script:PluginRoot '.codex-plugin\plugin.json') | ConvertFrom-Json

        $manifest.name | Should -Be 'fable-sonnet-orchestrator-kit'
        $manifest.skills | Should -Be './skills/'
        $manifest.PSObject.Properties.Name | Should -Not -Contain 'hooks'
        Test-Path -LiteralPath (Join-Path $script:PluginRoot 'hooks\hooks.json') | Should -BeTrue
    }

    It 'contains five complete skills with no scaffold placeholders' {
        $expected = @('executor', 'issue-triage', 'orch', 'orchestrator', 'pr-review')
        $actual = Get-ChildItem -Directory -LiteralPath (Join-Path $script:PluginRoot 'skills') |
            Select-Object -ExpandProperty Name | Sort-Object

        $actual | Should -Be ($expected | Sort-Object)
        foreach ($name in $expected) {
            $body = Get-Content -Raw -LiteralPath (Join-Path $script:PluginRoot "skills\$name\SKILL.md")
            $body | Should -Not -Match '\[TODO:'
            $body | Should -Match "(?m)^name: $([regex]::Escape($name))\r?$"
            $body | Should -Match '(?m)^description: .+'
        }
    }
}

Describe 'Codex custom-agent model mapping' {
    $cases = @(
        @{ File = 'sonnet-executor.toml'; Name = 'sonnet-executor'; Model = 'gpt-5.6-terra'; Effort = 'max'; Skill = 'executor' }
        @{ File = 'opus-executor.toml'; Name = 'opus-executor'; Model = 'gpt-5.6-sol'; Effort = 'max'; Skill = 'executor' }
        @{ File = 'haiku-executor.toml'; Name = 'haiku-executor'; Model = 'gpt-5.6-luna'; Effort = 'max'; Skill = 'executor' }
        @{ File = 'issue-triage.toml'; Name = 'issue-triage'; Model = 'gpt-5.6-terra'; Effort = 'max'; Skill = 'issue-triage' }
        @{ File = 'pr-reviewer.toml'; Name = 'pr-reviewer'; Model = 'gpt-5.6-terra'; Effort = 'max'; Skill = 'pr-review' }
    )

    It 'pins <Name> to <Model>/<Effort> and its binding skill' -ForEach $cases {
        $body = Get-Content -Raw -LiteralPath (Join-Path $script:CodexAgents $File)

        $body | Should -Match "(?m)^name = `"$([regex]::Escape($Name))`"\r?$"
        $body | Should -Match "(?m)^model = `"$([regex]::Escape($Model))`"\r?$"
        $body | Should -Match "(?m)^model_reasoning_effort = `"$([regex]::Escape($Effort))`"\r?$"
        $body | Should -Match "fable-sonnet-orchestrator-kit:$([regex]::Escape($Skill))"
    }
}

Describe 'Codex hook wiring' {
    It 'gates every executor tier and not the reviewer' {
        $hooks = Get-Content -Raw -LiteralPath (Join-Path $script:PluginRoot 'hooks\hooks.json') | ConvertFrom-Json
        $matcher = $hooks.hooks.SubagentStop[0].matcher

        $matcher | Should -Match 'sonnet-executor'
        $matcher | Should -Match 'opus-executor'
        $matcher | Should -Match 'haiku-executor'
        $matcher | Should -Not -Match 'pr-reviewer'
    }

    It 'ships the gate byte-for-byte with the tested Claude gate logic' {
        $claudeGate = Join-Path $script:RepoRoot '.claude\hooks\executor-stop-gate.ps1'
        $codexGate = Join-Path $script:PluginRoot 'hooks\executor-stop-gate.ps1'

        (Get-FileHash -Algorithm SHA256 -LiteralPath $codexGate).Hash |
            Should -Be (Get-FileHash -Algorithm SHA256 -LiteralPath $claudeGate).Hash
    }

    It 'injects the orchestrator skill only when .codex/orch.on exists' {
        $sandboxRepo = Join-Path $script:FixtureDir 'sandbox-repo'
        New-Item -ItemType Directory -Path $sandboxRepo -Force | Out-Null
        git -C $sandboxRepo init -q
        $inputJson = @{ cwd = $sandboxRepo; hook_event_name = 'SessionStart'; source = 'startup' } | ConvertTo-Json -Compress
        $sessionHook = Join-Path $script:PluginRoot 'hooks\session-start.ps1'

        $previousPluginRoot = $env:PLUGIN_ROOT
        $env:PLUGIN_ROOT = $script:PluginRoot
        try {
            $withoutFlag = $inputJson | pwsh -NoProfile -ExecutionPolicy Bypass -File $sessionHook
            ([string]($withoutFlag | Out-String)).Trim() | Should -BeNullOrEmpty

            New-Item -ItemType Directory -Path (Join-Path $sandboxRepo '.codex') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $sandboxRepo '.codex\orch.on') -Force | Out-Null
            $withFlag = $inputJson | pwsh -NoProfile -ExecutionPolicy Bypass -File $sessionHook
            ([string]($withFlag | Out-String)) | Should -Match '# orchestrator — the Codex main-agent operating model'
        } finally {
            $env:PLUGIN_ROOT = $previousPluginRoot
        }
    }
}
