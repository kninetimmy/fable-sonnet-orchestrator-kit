#Requires -Version 7.0

# Conditionally inject the orchestrator operating model for Codex sessions.
# Presence of <repo>/.codex/orch.on is the only enablement signal.

$ErrorActionPreference = 'SilentlyContinue'

try { $hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }

$cwd = $hookInput.cwd
if (-not $cwd) { $cwd = (Get-Location).Path }

$repoRoot = $null
try {
    $repoRoot = git -C $cwd rev-parse --show-toplevel 2>$null | Select-Object -First 1
} catch { }
if (-not $repoRoot) { $repoRoot = $cwd }

$flagPath = Join-Path $repoRoot '.codex\orch.on'
if (-not (Test-Path -LiteralPath $flagPath -PathType Leaf)) { exit 0 }

$pluginRoot = $env:PLUGIN_ROOT
if (-not $pluginRoot) { $pluginRoot = Split-Path $PSScriptRoot -Parent }
$skillPath = Join-Path $pluginRoot 'skills\orchestrator\SKILL.md'
if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { exit 0 }

Get-Content -Raw -LiteralPath $skillPath
exit 0
