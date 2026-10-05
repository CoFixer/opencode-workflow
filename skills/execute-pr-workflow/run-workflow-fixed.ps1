<#
.SYNOPSIS
    Compatibility wrapper for the Execute PR Workflow.

.DESCRIPTION
    All workflow logic now lives in run-workflow.ps1 (single source of truth),
    so this file and the canonical script can no longer drift apart. This file
    is intentionally pure ASCII to avoid the PowerShell 5.1 encoding trap where
    non-ASCII glyphs in a BOM-less UTF-8 file are read as ANSI "smart quotes"
    and corrupt parsing.

.NOTES
    Prefer calling run-workflow.ps1 directly. This wrapper exists for backwards
    compatibility with tooling that references run-workflow-fixed.ps1.
#>

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$DryRun,
    [string]$CustomBranchName,
    [string]$CommitMessage,
    [int]$MaxWaitMinutes,
    [int]$RunnerAcquireTimeoutSeconds
)

$scriptPath = Join-Path $PSScriptRoot "run-workflow.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "run-workflow.ps1 not found next to $($MyInvocation.MyCommand.Path)"
    exit 1
}

& $scriptPath @PSBoundParameters
exit $LASTEXITCODE
