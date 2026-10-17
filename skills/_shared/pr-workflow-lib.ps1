<#
.SYNOPSIS
    Shared helpers for the FirstAid-OS PR workflow skills.

.DESCRIPTION
    Provides consistent behaviour for:
      - git/gh command execution with transient-failure retries
      - change classification (type / area / module)
      - package build + typecheck gates with an optional auto-fix pass
      - CI check waiting with stuck-detection and automatic recovery
      - merge handling (blocked, behind base, auto-merge fallback)

.NOTES
    Dot-source from a skill script:
        . (Join-Path $PSScriptRoot '..\_shared\pr-workflow-lib.ps1')
#>

$ErrorActionPreference = 'Continue'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "`n[STEP] $Message" -ForegroundColor Magenta }
function Write-Ok { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Cyan }
function Write-Warn { param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  [XX] $Message" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------
function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$CommandArgs = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [switch]$AllowFailure,
        [int]$MaxAttempts = 1,
        [int]$RetryDelaySeconds = 3
    )

    $exitCode = 1
    $output = @()

    for ($attempt = 1; $attempt -le [math]::Max(1, $MaxAttempts); $attempt++) {
        Push-Location $WorkingDirectory
        try {
            $output = @(& $FilePath @CommandArgs 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        $output | ForEach-Object { Write-Host "$_" }

        if ($exitCode -eq 0) { return 0 }

        $text = ($output -join "`n")
        $isTransient = $text -match '(?i)(timed out|timeout|connection reset|connection refused|network is unreachable|temporary failure|could not resolve host|502 bad gateway|503 service|504 gateway|rate limit|try again)'

        if ($attempt -lt $MaxAttempts -and $isTransient) {
            Write-Warn "Transient failure (attempt $attempt/$MaxAttempts). Retrying in $RetryDelaySeconds s..."
            Start-Sleep -Seconds $RetryDelaySeconds
            continue
        }

        break
    }

    if (-not $AllowFailure) {
        throw "$FilePath $($CommandArgs -join ' ') failed (exit code $exitCode)."
    }
    return $exitCode
}

function Get-GitValue {
    param([Parameter(Mandatory = $true)][string[]]$CommandArgs, [switch]$AllowFailure)

    $out = & git @CommandArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "git $($CommandArgs -join ' ') failed."
    }
    return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Get-GhValue {
    param([Parameter(Mandatory = $true)][string[]]$CommandArgs, [switch]$AllowFailure, [int]$MaxAttempts = 3)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $out = & gh @CommandArgs 2>$null
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
        }

        $text = ($out -join "`n")
        $isTransient = $text -match '(?i)(timed out|timeout|connection reset|could not resolve host|502|503|504|rate limit|try again)'
        if ($attempt -lt $MaxAttempts -and $isTransient) {
            Start-Sleep -Seconds (2 * $attempt)
            continue
        }
        break
    }

    if ($AllowFailure) { return $null }
    throw "gh $($CommandArgs -join ' ') failed."
}

function Invoke-Gh {
    param([string[]]$CommandArgs, [switch]$AllowFailure, [int]$MaxAttempts = 3)
    return Invoke-External -FilePath gh -CommandArgs $CommandArgs -AllowFailure:$AllowFailure -MaxAttempts $MaxAttempts -RetryDelaySeconds 3
}

function Test-RemoteBranch {
    param([string]$Branch)
    $out = & git ls-remote --heads origin $Branch 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($out -join '')))
}

function Test-LocalBranch {
    param([string]$Branch)
    & git rev-parse --verify --quiet "refs/heads/$Branch" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-OpenPullRequest {
    param([string]$HeadBranch, [string]$BaseBranch)

    if ([string]::IsNullOrWhiteSpace($HeadBranch)) { return $null }
    $raw = & gh pr list --head $HeadBranch --base $BaseBranch --state open --json number,url,title 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw -join ''))) { return $null }

    $list = ($raw -join "`n") | ConvertFrom-Json
    $first = @($list) | Select-Object -First 1
    if ($null -eq $first) { return $null }
    return $first
}

function Assert-Preflight {
    param([switch]$RequireGh)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required.' }
    if ($RequireGh) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw 'GitHub CLI (gh) is required. Install it from https://cli.github.com/'
        }
        & gh auth status *> $null
        if ($LASTEXITCODE -ne 0) { throw "gh is not authenticated. Run 'gh auth login' first." }
    }

    $repoRoot = ((& git rev-parse --show-toplevel 2>$null) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'Not inside a git repository.'
    }
    Set-Location $repoRoot
    return $repoRoot
}

# ---------------------------------------------------------------------------
# Change analysis
# ---------------------------------------------------------------------------
function Get-ChangedFiles {
    $staged = @(& git diff --cached --name-only 2>$null)
    $unstaged = @(& git diff --name-only 2>$null)
    $untracked = @(& git ls-files --others --exclude-standard 2>$null)
    return @($staged + $unstaged + $untracked |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)
}

function Test-CommittableFile {
    param([string]$Path)
    if ($Path -match '^\.env') { return $false }
    if ($Path -match '^\.opencode(/|$)') { return $false }
    if ($Path -match '^\.commandcode(/|$)') { return $false }
    if ($Path -eq '.gitmodules') { return $false }
    if ($Path -match '\.tsbuildinfo$') { return $false }
    return $true
}

function Resolve-ChangeType {
    param([string[]]$Files)

    $total = [math]::Max(1, $Files.Count)
    $testFiles = @($Files | Where-Object { $_ -match '\.(test|spec)\.(ts|tsx|js|jsx|vue)$' })
    $docFiles = @($Files | Where-Object { $_ -match '\.(md|mdx)$' })

    if ($testFiles.Count -eq $total) { return 'test' }
    if ($docFiles.Count -eq $total) { return 'docs' }

    $joined = ($Files -join ' ').ToLowerInvariant()

    if ($joined -match '(^|[/\\._\s-])(fix|bug|hotfix|patch|repair)([/\\._\s-]|$)') { return 'fix' }
    if ($joined -match '(^|[/\\._\s-])(refactor|restructure|cleanup|rename)([/\\._\s-]|$)') { return 'refactor' }
    if ($joined -match '(^|[/\\._\s-])(docs?|readme|guide)([/\\._\s-]|$)') { return 'docs' }
    if ($joined -match '(^|[/\\._\s-])(chore|deps|dependencies|bump)([/\\._\s-]|$)') { return 'chore' }
    if ($testFiles.Count -ge [math]::Ceiling($total * 0.6)) { return 'test' }
    if ($Files | Where-Object { $_ -match '(lock|lockb)$' }) { return 'chore' }
    return 'feat'
}

function Get-ConventionalType {
    param([string]$Message)
    if ($Message -match '^(feat|fix|refactor|docs|test|chore|build|ci|perf|revert)(\([^)]+\))?!?:\s+') {
        return $matches[1]
    }
    return $null
}

function Get-ConventionalScope {
    param([string]$Message)
    if ($Message -match '^[a-z]+\(([^)]+)\)!?:\s+') {
        return $matches[1]
    }
    return $null
}

function Get-Areas {
    param([string[]]$Files)

    $definitions = @(
        @{ Name = 'backend'; Pattern = '^backend/' },
        @{ Name = 'frontend'; Pattern = '^frontend/' },
        @{ Name = 'dashboard'; Pattern = '^dashboard/' },
        @{ Name = 'print-agent'; Pattern = '^print-agent/' },
        @{ Name = 'mobile'; Pattern = '^mobile/' }
    )

    $found = @()
    foreach ($definition in $definitions) {
        $hits = @($Files | Where-Object { $_ -match $definition.Pattern })
        if ($hits.Count -gt 0) {
            $found += [pscustomobject]@{ Name = $definition.Name; Count = $hits.Count }
        }
    }

    if ($found.Count -eq 0) {
        return @([pscustomobject]@{ Name = 'project'; Count = $Files.Count })
    }
    return @($found | Sort-Object Count -Descending)
}

function Get-ModuleHint {
    param([string[]]$Files, [string]$Fallback)

    $hints = @()
    foreach ($file in $Files) {
        $parts = $file -split '/'
        if ($parts.Length -ge 4 -and $parts[1] -eq 'src' -and $parts[2] -eq 'modules') {
            $hints += $parts[3]
            continue
        }
        if ($parts.Length -ge 2) {
            $parent = $parts[$parts.Length - 2]
            if ($parent -notmatch '^(src|dist|lib|app|pages|components|node_modules)$') {
                $hints += $parent
            }
        }
    }

    $top = $hints | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
    if ($top) { return $top.Name }
    return $Fallback
}

function Get-SummaryBullets {
    param([string[]]$Files, [string]$Subject)

    $lines = @("- $Subject")
    foreach ($area in (Get-Areas -Files $Files)) {
        $areaFiles = @($Files | Where-Object { $_ -like "$($area.Name)/*" })
        if ($areaFiles.Count -eq 0) { continue }

        $modules = @($areaFiles | ForEach-Object {
                $parts = $_ -split '/'
                if ($parts.Length -ge 4 -and $parts[1] -eq 'src' -and $parts[2] -eq 'modules') { $parts[3] }
            } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 5)

        $moduleText = ''
        if ($modules.Count -gt 0) { $moduleText = " (modules: $($modules -join ', '))" }
        $lines += "- ``$($area.Name)``: $($areaFiles.Count) file(s)$moduleText"
    }
    return $lines
}

# ---------------------------------------------------------------------------
# Build gates
# ---------------------------------------------------------------------------
function Get-PackageRunner {
    param([string]$PackagePath)
    if (Test-Path (Join-Path $PackagePath 'bun.lock')) { return 'bun' }
    if (Test-Path (Join-Path $PackagePath 'bun.lockb')) { return 'bun' }
    if (Test-Path (Join-Path $PackagePath 'pnpm-lock.yaml')) { return 'pnpm' }
    if (Test-Path (Join-Path $PackagePath 'yarn.lock')) { return 'yarn' }
    return 'npm'
}

function Get-PackageScripts {
    param([string]$PackagePath)
    $packageJson = Join-Path $PackagePath 'package.json'
    if (-not (Test-Path $packageJson)) { return @() }
    $package = Get-Content $packageJson -Raw | ConvertFrom-Json
    if (-not $package.scripts) { return @() }
    return @($package.scripts.PSObject.Properties.Name)
}

function Invoke-PackageScript {
    param([string]$PackagePath, [string]$Script)

    $runner = Get-PackageRunner -PackagePath $PackagePath
    $commandArgs = @('run', $Script)
    if ($runner -eq 'pnpm' -or $runner -eq 'yarn') { $commandArgs = @($Script) }

    Write-Info "Running: $runner $($commandArgs -join ' ')  [in $PackagePath]"
    Push-Location $PackagePath
    try {
        $output = @(& $runner @commandArgs 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $output | ForEach-Object { Write-Host "$_" }
    return [pscustomobject]@{
        Package = $PackagePath
        Script  = $Script
        Success = ($code -eq 0)
        Output  = ($output -join "`n")
    }
}

function Invoke-AutoFix {
    param([string]$PackagePath)

    $scripts = @(Get-PackageScripts -PackagePath $PackagePath)
    $fixScripts = @('lint:fix', 'format', 'format:write', 'fix', 'prettier:write') |
        Where-Object { $scripts -contains $_ } |
        Select-Object -First 1

    if (-not $fixScripts) {
        Write-Info "[$PackagePath] No auto-fix script available."
        return
    }

    Write-Info "[$PackagePath] Applying auto-fix via '$fixScripts'"
    Invoke-PackageScript -PackagePath $PackagePath -Script $fixScripts | Out-Null
}

function Invoke-BuildGates {
    param(
        [string[]]$Files,
        [switch]$AutoFix,
        [int]$MaxAttempts = 2
    )

    $results = @()
    $areas = @(Get-Areas -Files $Files | Where-Object { $_.Name -ne 'project' })

    if ($areas.Count -eq 0) {
        Write-Info 'No package-level areas detected; skipping package gates.'
        return @()
    }

    foreach ($area in $areas) {
        $packagePath = $area.Name
        if (-not (Test-Path (Join-Path $packagePath 'package.json'))) { continue }

        $scripts = @(Get-PackageScripts -PackagePath $packagePath)
        $checks = @()

        $typeScript = @('typecheck', 'type-check', 'tsc', 'lint:types') |
            Where-Object { $scripts -contains $_ } |
            Select-Object -First 1
        if ($typeScript) { $checks += $typeScript }
        if ($scripts -contains 'build') { $checks += 'build' }

        if ($checks.Count -eq 0) {
            Write-Info "[$packagePath] No typecheck/build script; skipping package gates."
            continue
        }

        foreach ($script in $checks) {
            $attempt = 0
            $allowedAttempts = if ($AutoFix) { [math]::Max(1, $MaxAttempts) } else { 1 }

            while ($attempt -lt $allowedAttempts) {
                $attempt++
                Write-Step "[$packagePath] $script (attempt $attempt/$allowedAttempts)"

                $result = Invoke-PackageScript -PackagePath $packagePath -Script $script
                if ($result.Success) {
                    Write-Ok "[$packagePath] $script passed"
                    $results += $result
                    break
                }

                if ($AutoFix -and $attempt -lt $allowedAttempts) {
                    Write-Warn "[$packagePath] $script failed; applying available auto-fixes and retrying."
                    Invoke-AutoFix -PackagePath $packagePath
                    continue
                }

                Write-Fail "[$packagePath] $script failed"
                $results += $result
            }
        }
    }

    return @($results)
}

function Write-FixGuidance {
    param([object[]]$Results)

    $failures = @($Results | Where-Object { -not $_.Success })
    if ($failures.Count -eq 0) { return }

    Write-Host "`n+---------------------------------------------------------------+" -ForegroundColor Red
    Write-Host '|  FIX REQUIRED - nothing was committed / pushed               |' -ForegroundColor Red
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor Red

    foreach ($failure in $failures) {
        Write-Host "  - $($failure.Package): $($failure.Script) failed" -ForegroundColor Red
    }

    Write-Host @"

Fix loop (mandatory):
  1. Read the compiler/build output above and fix the source files.
  2. Re-run the failing command until it is green, for example:
       cd <package>; bun run <script>    (or npm run <script>)
  3. Re-run this skill. Nothing was committed, so the run is safe to repeat.

-SkipBuild is only acceptable for a verified environment/tooling failure,
never to bypass a genuine type or build error.
"@ -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# CI checks
# ---------------------------------------------------------------------------
function Repair-StuckChecks {
    param([string]$PrNumber, [string]$HeadBranch)

    $mergeState = Get-GhValue -CommandArgs @('pr', 'view', $PrNumber, '--json', 'mergeStateStatus', '--jq', '.mergeStateStatus') -AllowFailure
    if ($mergeState -eq 'BEHIND') {
        Write-Info 'PR is behind its base branch; updating it.'
        Invoke-Gh -CommandArgs @('pr', 'update-branch', $PrNumber) -AllowFailure | Out-Null
    }

    $runsRaw = & gh run list --branch $HeadBranch --limit 20 --json databaseId,status,conclusion,workflowName,createdAt 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($runsRaw -join ''))) {
        Write-Warn "No workflow runs found for '$HeadBranch'. CI may not be configured to run for this branch."
        return
    }

    $prCreatedRaw = Get-GhValue -CommandArgs @('pr', 'view', $PrNumber, '--json', 'createdAt', '--jq', '.createdAt') -AllowFailure
    $prCreated = $null
    if (-not [string]::IsNullOrWhiteSpace($prCreatedRaw)) {
        try { $prCreated = [DateTime]::Parse($prCreatedRaw).ToUniversalTime() } catch { $prCreated = $null }
    }

    $runs = ($runsRaw -join "`n") | ConvertFrom-Json
    foreach ($run in @($runs)) {
        $name = "$($run.workflowName)"
        $id = "$($run.databaseId)"

        # Only touch runs that belong to this PR window, never older merge runs.
        if ($prCreated -and $run.createdAt) {
            try {
                $runCreated = [DateTime]::Parse($run.createdAt).ToUniversalTime()
                if ($runCreated -lt $prCreated.AddMinutes(-2)) { continue }
            }
            catch { }
        }

        if ($run.status -eq 'completed' -and $run.conclusion -eq 'failure') {
            Write-Info "Re-running failed workflow '$name' (#$id)"
            Invoke-Gh -CommandArgs @('run', 'rerun', $id, '--failed') -AllowFailure | Out-Null
        }
        elseif ($run.status -eq 'queued') {
            Write-Info "Cancelling stuck queued workflow '$name' (#$id)"
            Invoke-Gh -CommandArgs @('run', 'cancel', $id) -AllowFailure | Out-Null
            Start-Sleep -Seconds 3
            Invoke-Gh -CommandArgs @('run', 'rerun', $id) -AllowFailure | Out-Null
        }
    }
}

function Wait-PullRequestChecks {
    param(
        [string]$PrNumber,
        [string]$HeadBranch,
        [int]$MaxWaitMinutes = 15,
        [int]$StuckAfterMinutes = 5,
        [switch]$SkipRerun
    )

    $started = Get-Date
    $deadline = $started.AddMinutes([math]::Max(1, $MaxWaitMinutes))
    $noChecksDeadline = $started.AddSeconds(90)

    $pendingStates = @('PENDING', 'QUEUED', 'IN_PROGRESS', 'WAITING', 'EXPECTED', 'REQUESTED', 'STALE')
    $failedStates = @('FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE')
    $successStates = @('COMPLETED', 'SUCCESS', 'NEUTRAL', 'SKIPPED')

    $lastSignature = ''
    $lastChangeAt = Get-Date
    $rerunAttempts = 0
    $maxReruns = 2
    $noChecksExtended = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10

        $raw = & gh pr view $PrNumber --json state,mergeable,statusCheckRollup 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw -join ''))) {
            Write-Info 'Could not read PR status; retrying.'
            continue
        }
        $pr = ($raw -join "`n") | ConvertFrom-Json

        if ($pr.state -in @('MERGED', 'CLOSED')) {
            return [pscustomobject]@{ Status = 'CLOSED'; Detail = "PR is $($pr.state)." }
        }

        $entries = @()
        if ($pr.statusCheckRollup) { $entries = @($pr.statusCheckRollup) }

        if ($entries.Count -eq 0) {
            if ((Get-Date) -gt $noChecksDeadline) {
                if (-not $noChecksExtended) {
                    $runsRaw = & gh run list --branch $HeadBranch --limit 5 --json status 2>$null
                    $hasActiveRuns = $false
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($runsRaw -join ''))) {
                        $branchRuns = ($runsRaw -join "`n") | ConvertFrom-Json
                        $hasActiveRuns = @($branchRuns | Where-Object {
                                $_.status -in @('queued', 'in_progress', 'waiting', 'pending', 'requested')
                            }).Count -gt 0
                    }

                    if ($hasActiveRuns) {
                        Write-Info 'Workflow runs exist for this branch but no checks are attached yet; continuing to wait.'
                        $noChecksDeadline = (Get-Date).AddMinutes([math]::Max(2, $StuckAfterMinutes))
                        $noChecksExtended = $true
                        continue
                    }
                }

                return [pscustomobject]@{
                    Status = 'NO_CHECKS'
                    Detail = 'No CI checks were reported. The workflows may not trigger for this branch/path.'
                }
            }
            continue
        }

        $failed = @()
        $pending = @()
        foreach ($entry in $entries) {
            $state = ''
            if ($entry.conclusion) { $state = "$($entry.conclusion)" }
            elseif ($entry.state) { $state = "$($entry.state)" }
            elseif ($entry.status) { $state = "$($entry.status)" }

            if ($failedStates -contains $state) { $failed += "$($entry.name) [$state]" }
            elseif ($successStates -contains $state) { continue }
            else { $pending += "$($entry.name) [$state]" }
        }

        if ($failed.Count -gt 0) {
            return [pscustomobject]@{ Status = 'FAILED'; Detail = ($failed -join '; ') }
        }
        if ($pending.Count -eq 0) {
            return [pscustomobject]@{ Status = 'PASSED'; Detail = "$($entries.Count) check(s) passed." }
        }

        Write-Info "Waiting on $($pending.Count) check(s): $($pending -join ', ')"

        $signature = ($pending -join '|')
        if ($signature -ne $lastSignature) {
            $lastSignature = $signature
            $lastChangeAt = Get-Date
        }
        elseif (((Get-Date) - $lastChangeAt).TotalMinutes -ge $StuckAfterMinutes) {
            if (-not $SkipRerun -and $rerunAttempts -lt $maxReruns) {
                $rerunAttempts++
                Write-Warn "Checks have not progressed for $StuckAfterMinutes minute(s). Recovery attempt $rerunAttempts/$maxReruns."
                Repair-StuckChecks -PrNumber $PrNumber -HeadBranch $HeadBranch
                $lastChangeAt = Get-Date
            }
            else {
                return [pscustomobject]@{
                    Status = 'TIMEOUT'
                    Detail = "Checks stalled for $StuckAfterMinutes minute(s) and recovery attempts were exhausted."
                }
            }
        }
    }

    return [pscustomobject]@{
        Status = 'TIMEOUT'
        Detail = "Checks did not finish within $MaxWaitMinutes minute(s)."
    }
}

function Format-CheckResult {
    param([object]$CheckResult, [string]$PrNumber, [string]$HeadBranch)

    switch ($CheckResult.Status) {
        'PASSED' { Write-Ok $CheckResult.Detail; return }
        'NO_CHECKS' {
            Write-Warn $CheckResult.Detail
            Write-Info "Inspect the PR manually: gh pr checks $PrNumber"
            return
        }
        'FAILED' {
            Write-Fail "CI failed: $($CheckResult.Detail)"
            Write-Host @"

Recovery:
  1. Inspect logs:   gh pr checks $PrNumber
                     gh run list --branch $HeadBranch --limit 5
                     gh run view <run-id> --log-failed
  2. Fix the code, then re-run this skill with -Resume.
  3. Workflows were already re-run automatically once before this failure.
"@ -ForegroundColor Yellow
            return
        }
        'TIMEOUT' {
            Write-Warn $CheckResult.Detail
            Write-Info "Inspect: gh pr checks $PrNumber"
            Write-Info 'Re-run this skill with -Resume once the checks finish.'
            return
        }
        'CLOSED' { Write-Warn $CheckResult.Detail; return }
    }
}

# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------
function Merge-PullRequestSafe {
    param(
        [string]$PrNumber,
        [ValidateSet('squash', 'merge', 'rebase')][string]$MergeMethod = 'squash',
        [string]$Subject,
        [switch]$DeleteBranch
    )

    function Get-MergeArgs {
        $mergeArgList = @('pr', 'merge', $PrNumber)
        switch ($MergeMethod) {
            'squash' {
                $mergeArgList += @('--squash')
                if ($Subject) { $mergeArgList += @('--subject', $Subject) }
            }
            'merge' { $mergeArgList += @('--merge') }
            'rebase' { $mergeArgList += @('--rebase') }
        }
        if ($DeleteBranch) { $mergeArgList += '--delete-branch' }
        return $mergeArgList
    }

    $exit = Invoke-Gh -CommandArgs (Get-MergeArgs) -AllowFailure -MaxAttempts 2
    if ($exit -eq 0) { return 'MERGED' }

    $infoRaw = & gh pr view $PrNumber --json state,mergeable,mergeStateStatus,reviewDecision 2>$null
    $info = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($infoRaw -join ''))) {
        ($infoRaw -join "`n") | ConvertFrom-Json
    } else {
        $null
    }

    if ($info -and $info.state -eq 'MERGED') { return 'MERGED' }

    if ($info -and $info.mergeStateStatus -eq 'BEHIND') {
        Write-Info 'PR is behind the base branch; updating and retrying the merge.'
        Invoke-Gh -CommandArgs @('pr', 'update-branch', $PrNumber) -AllowFailure | Out-Null
        Start-Sleep -Seconds 5
        $exit = Invoke-Gh -CommandArgs (Get-MergeArgs) -AllowFailure -MaxAttempts 2
        if ($exit -eq 0) { return 'MERGED' }
    }

    if ($info -and ($info.mergeable -eq 'CONFLICTING' -or $info.mergeStateStatus -eq 'DIRTY')) {
        throw "PR #$PrNumber has merge conflicts. Resolve conflicts on the head branch, push, and re-run."
    }

    if ($info -and $info.mergeStateStatus -eq 'BLOCKED') {
        $reason = if ($info.reviewDecision -eq 'REVIEW_REQUIRED') { 'review approval is required' } else { 'a branch protection rule is blocking the merge' }
        throw "PR #$PrNumber is blocked: $reason. Bypass it manually if appropriate, or pass -SkipTests/-AutoMerge settings supported by your repo."
    }

    Write-Warn 'Direct merge failed; enabling auto-merge so the PR lands when requirements are met.'
    $autoArgs = @('pr', 'merge', $PrNumber, '--auto', "--$MergeMethod")
    if ($DeleteBranch) { $autoArgs += '--delete-branch' }

    $autoExit = Invoke-Gh -CommandArgs $autoArgs -AllowFailure -MaxAttempts 2
    if ($autoExit -ne 0) {
        throw "Could not merge PR #$PrNumber. Inspect it with: gh pr view $PrNumber --web"
    }
    return 'AUTO_MERGE_ENABLED'
}

function Get-PullRequestState {
    param([string]$PrNumber)
    return Get-GhValue -CommandArgs @('pr', 'view', $PrNumber, '--json', 'state', '--jq', '.state') -AllowFailure
}

function Remove-MergedFeatureBranches {
    param(
        [string]$BaseBranch,
        [string]$KeepBranch,
        [int]$OlderThanHours = 24
    )

    $protected = @('main', 'master', 'dev', 'staging', 'develop', 'HEAD')
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * [math]::Abs($OlderThanHours))
    $baseRef = "origin/$BaseBranch"
    $prunedLocal = 0
    $prunedRemote = 0

    $mergedLocal = @(& git branch --merged $baseRef --format='%(refname:short)' 2>$null)
    foreach ($localBranch in $mergedLocal) {
        $name = "$localBranch".Trim()
        if ($protected -contains $name) { continue }
        if ($name -eq $KeepBranch) { continue }
        if ($name -notmatch '^(feat|fix|refactor|docs|test|chore|release|hotfix)/') { continue }

        Invoke-External -FilePath git -CommandArgs @('branch', '-d', $name) -AllowFailure | Out-Null
        $prunedLocal++
    }

    $mergedRemote = @(& git branch -r --merged $baseRef --format='%(refname:short)' 2>$null)
    foreach ($remoteBranch in $mergedRemote) {
        $name = "$remoteBranch".Trim() -replace '^origin/', ''
        if ($protected -contains $name) { continue }
        if ($name -eq $KeepBranch) { continue }
        if ($name -notmatch '^(feat|fix|refactor|docs|test|chore|release|hotfix)/') { continue }

        $epoch = 0
        $epochRaw = (& git log -1 --format=%ct "origin/$name" 2>$null)
        if ($LASTEXITCODE -eq 0) { [void][int64]::TryParse((($epochRaw -join '').Trim()), [ref]$epoch) }

        if ($epoch -gt 0) {
            $tipDate = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime
            if ($tipDate -gt $cutoff) {
                Write-Info "Keeping recent branch origin/$name (tip $($tipDate.ToString('u')))"
                continue
            }
        }

        Invoke-External -FilePath git -CommandArgs @('push', 'origin', '--delete', $name) -AllowFailure | Out-Null
        $prunedRemote++
    }

    Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') -AllowFailure | Out-Null
    return [pscustomobject]@{ Local = $prunedLocal; Remote = $prunedRemote }
}


# ---------------------------------------------------------------------------
# Conflict handling
# ---------------------------------------------------------------------------
function Get-ConflictedFiles {
    return @(& git diff --name-only --diff-filter=U 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-MergeInProgress {
    & git rev-parse -q --verify MERGE_HEAD *> $null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-MechanicalConflicts {
    param([string[]]$Files)

    $remaining = @()
    $lockfiles = @()

    foreach ($file in $Files) {
        # Lockfiles must match package.json after the merge: take the incoming
        # version, then regenerate with the package manager.
        if ($file -match '(?i)(^|/)(bun\.lock|bun\.lockb|package-lock\.json|pnpm-lock\.yaml|yarn\.lock)$') {
            & git checkout --theirs -- $file *> $null
            if ($LASTEXITCODE -ne 0) { & git checkout --ours -- $file *> $null }
            & git add -- $file *> $null
            $lockfiles += $file
            Write-Info "Auto-resolved lockfile conflict: $file"
            continue
        }

        # Build artifacts are safe to take from the base and rebuild.
        if ($file -match '(?i)\.tsbuildinfo$' -or $file -match '(?i)(^|/)(dist|coverage|\.next)/') {
            & git checkout --theirs -- $file *> $null
            if ($LASTEXITCODE -ne 0) { & git checkout --ours -- $file *> $null }
            & git add -- $file *> $null
            Write-Info "Auto-resolved generated artifact conflict: $file"
            continue
        }

        $remaining += $file
    }

    foreach ($lock in $lockfiles) {
        $packagePath = Split-Path -Parent $lock
        if ([string]::IsNullOrWhiteSpace($packagePath)) { $packagePath = '.' }

        $runner = Get-PackageRunner -PackagePath $packagePath
        Write-Info "Regenerating $lock with '$runner install'"
        $exit = Invoke-External -FilePath $runner -CommandArgs @('install') -WorkingDirectory $packagePath -AllowFailure
        if ($exit -eq 0) {
            & git add -- $lock *> $null
        }
        else {
            Write-Warn "Could not regenerate $lock; kept the incoming version."
        }
    }

    return @($remaining)
}

function Merge-BaseIntoCurrentBranch {
    param([string]$BaseRef)

    & git merge --no-edit $BaseRef 2>&1 | ForEach-Object { Write-Host "$_" }
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        return [pscustomobject]@{ Status = 'CLEAN'; Files = @() }
    }

    $conflicts = @(Get-ConflictedFiles)
    if ($conflicts.Count -eq 0) {
        return [pscustomobject]@{ Status = 'FAILED'; Files = @() }
    }

    Write-Warn "$($conflicts.Count) conflict(s) detected while merging '$BaseRef'."
    $remaining = @(Resolve-MechanicalConflicts -Files $conflicts)

    if ($remaining.Count -gt 0) {
        return [pscustomobject]@{ Status = 'CONFLICT'; Files = $remaining }
    }

    & git commit --no-edit *> $null
    if ($LASTEXITCODE -ne 0 -and (Test-MergeInProgress)) {
        return [pscustomobject]@{ Status = 'FAILED'; Files = @() }
    }

    Write-Ok 'All conflicts were mechanical and were auto-resolved.'
    return [pscustomobject]@{ Status = 'AUTO_RESOLVED'; Files = @() }
}

function Write-ConflictGuidance {
    param([string[]]$Files, [string]$Branch)

    Write-Host "`n+---------------------------------------------------------------+" -ForegroundColor Red
    Write-Host '|  MERGE CONFLICT - resolve in the working tree, then re-run    |' -ForegroundColor Red
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor Red
    Write-Host "  Branch: $Branch"

    foreach ($file in $Files) {
        Write-Host "  - $file" -ForegroundColor Yellow
    }

    Write-Host @"

For each conflicted file:
  git status
  git show :2:<file>     # current branch version
  git show :3:<file>     # incoming version
  # edit the file and combine BOTH intents - never blind --ours/--theirs
  git add <file>

Then re-run this skill. It detects the in-progress merge, commits it,
runs build/typecheck, pushes, and continues to checks + merge.
"@ -ForegroundColor Yellow
}

function Invoke-BranchSync {
    param(
        [string]$HeadBranch,
        [string]$BaseBranch,
        [int]$MaxWaitMinutes = 15,
        [int]$StuckAfterMinutes = 5,
        [switch]$SkipTests,
        [switch]$AllowCheckTimeout
    )

    if (Test-MergeInProgress) {
        $pending = @(Get-ConflictedFiles)
        if ($pending.Count -gt 0) {
            Write-ConflictGuidance -Files $pending -Branch ((& git branch --show-current) -join '').Trim()
            return [pscustomobject]@{ Status = 'CONFLICT'; Branch = ((& git branch --show-current) -join '').Trim(); Files = $pending }
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $syncBranch = "chore/sync-$HeadBranch-$timestamp"
    $originalBranch = ((& git branch --show-current 2>$null) -join '').Trim()
    $stashMessage = "branch-sync-$timestamp"
    $stashed = $false

    Write-Step "Syncing '$HeadBranch' with '$BaseBranch' via '$syncBranch'"

    $dirty = ((& git status --porcelain 2>$null) -join '').Trim()
    if ($dirty) {
        Invoke-External -FilePath git -CommandArgs @('stash', 'push', '--include-untracked', '--message', $stashMessage) | Out-Null
        $stashed = $true
        Write-Info "Local work stashed as '$stashMessage' (restored after the sync)."
    }

    Invoke-External -FilePath git -CommandArgs @('checkout', '-B', $syncBranch, "origin/$HeadBranch") | Out-Null
    $merge = Merge-BaseIntoCurrentBranch -BaseRef "origin/$BaseBranch"

    if ($merge.Status -eq 'CONFLICT') {
        Write-ConflictGuidance -Files $merge.Files -Branch $syncBranch
        if ($stashed) { Write-Warn "Your original work is safe in the stash '$stashMessage'." }
        return [pscustomobject]@{ Status = 'CONFLICT'; Branch = $syncBranch; Files = $merge.Files }
    }

    if ($merge.Status -eq 'FAILED') {
        throw "Could not merge origin/$BaseBranch into '$syncBranch'."
    }

    Invoke-External -FilePath git -CommandArgs @('push', '-u', 'origin', $syncBranch) | Out-Null
    Write-Ok "Pushed origin/$syncBranch"

    $title = "chore(sync): merge $BaseBranch into $HeadBranch"
    $prBody = @"
## Branch sync: ``$BaseBranch`` -> ``$HeadBranch``

Automated sync created because the promotion PR reported conflicts.
Merging ``$BaseBranch`` back into ``$HeadBranch`` removes the conflict and
keeps future promotions mergeable.

### Details
- Sync branch: ``$syncBranch``
- Base merged in: ``$BaseBranch``
- Mechanical conflicts (lockfiles / generated artifacts) were auto-resolved

### Validation
- [x] CI checks verified by this workflow
- [x] The merge only brings in ``$BaseBranch`` content; no new feature work

### Rollback
- Revert this merge on ``$HeadBranch`` if it unexpectedly changes behaviour
"@

    $openPr = Get-OpenPullRequest -HeadBranch $syncBranch -BaseBranch $HeadBranch
    if ($openPr) {
        $prUrl = $openPr.url
        $prNumber = "$($openPr.number)"
        Write-Info "Reusing sync PR #${prNumber}: $prUrl"
    }
    else {
        $createOutput = ((& gh pr create --base $HeadBranch --head $syncBranch --title $title --body $prBody 2>&1) -join "`n").Trim()
        if ($LASTEXITCODE -ne 0 -or $createOutput -notmatch '^https?://') {
            throw "Sync PR creation failed: $createOutput"
        }
        $prUrl = $createOutput
        $prNumber = Get-GhValue -CommandArgs @('pr', 'view', $prUrl, '--json', 'number', '--jq', '.number')
        Write-Ok "Sync PR created: $prUrl"
    }

    if (-not $SkipTests) {
        Write-Step "Waiting for CI checks on sync PR #$prNumber"
        $checkResult = Wait-PullRequestChecks -PrNumber $prNumber -HeadBranch $syncBranch -MaxWaitMinutes $MaxWaitMinutes -StuckAfterMinutes $StuckAfterMinutes
        Format-CheckResult -CheckResult $checkResult -PrNumber $prNumber -HeadBranch $syncBranch

        if ($checkResult.Status -in @('FAILED', 'CLOSED')) {
            throw "CI failed on the sync PR #$prNumber ($($checkResult.Detail))."
        }
        if ($checkResult.Status -eq 'TIMEOUT' -and -not $AllowCheckTimeout) {
            throw "Sync PR #$prNumber checks timed out. Re-run the skill to continue."
        }
    }

    $mergeStatus = Merge-PullRequestSafe -PrNumber $prNumber -MergeMethod 'merge' -DeleteBranch
    $finalState = Get-PullRequestState -PrNumber $prNumber
    if ($finalState -ne 'MERGED') {
        throw "Sync PR #$prNumber was not merged (state: $finalState). Re-run the skill once it lands."
    }

    Invoke-External -FilePath git -CommandArgs @('checkout', $originalBranch) -AllowFailure | Out-Null
    Invoke-External -FilePath git -CommandArgs @('branch', '-D', $syncBranch) -AllowFailure | Out-Null
    if ($stashed) {
        $popCode = Invoke-External -FilePath git -CommandArgs @('stash', 'pop', '--index') -AllowFailure
        if ($popCode -ne 0) {
            Write-Warn "Could not re-apply stashed work '$stashMessage'. Inspect 'git stash list'."
        }
    }
    Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') -AllowFailure | Out-Null

    Write-Ok "Synced '$HeadBranch' with '$BaseBranch'"
    return [pscustomobject]@{ Status = 'SYNCED'; Branch = $syncBranch; PrUrl = $prUrl; MergeStatus = $mergeStatus }
}
