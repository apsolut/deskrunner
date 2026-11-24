#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  deskrunner: GitHub Actions runners on your Windows PC.
  The target is an organization (`my-org`) or a single repo (`owner/repo`).

.EXAMPLE
  ./deskrunner.ps1 doctor
  ./deskrunner.ps1 savings owner/repo
  ./deskrunner.ps1 init C:\path\to\checkout
  ./deskrunner.ps1 start owner/repo -Count 2
  ./deskrunner.ps1 start my-org -Docker
  ./deskrunner.ps1 stop owner/repo
  ./deskrunner.ps1 status
  ./deskrunner.ps1 logs owner/repo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'update', 'doctor', 'init', 'savings')]
    [string]$Action,

    # Organization name or owner/repo. Falls back to DEFAULT_TARGET in .env.
    # For `init` this is the path to a repo checkout (default: current folder).
    [Parameter(Position = 1)]
    [string]$Target,

    # Number of parallel runners for this target (start and restart).
    [ValidateRange(1, 16)]
    [int]$Count = 1,

    # Give jobs access to Docker Desktop (start and restart). Off by default.
    [switch]$Docker,

    # Do not set or delete the repo's RUNNER variable (start, restart, stop).
    [switch]$NoSwitch,

    # Show what `init` would change without writing files.
    [switch]$DryRun,

    # How many days of usage `savings` reads.
    [ValidateRange(1, 90)]
    [int]$Days = 30
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw "deskrunner supports Windows only (Windows 11, Docker Desktop, PowerShell 7, 1Password)."
}

$envFile = Join-Path $PSScriptRoot '.env'
$composeFile = Join-Path $PSScriptRoot 'compose.yaml'
$composeDockerFile = Join-Path $PSScriptRoot 'compose.docker.yaml'
$projectPrefix = 'deskrunner-'

# The repo variable that workflows read: runs-on: ${{ vars.RUNNER || 'ubuntu-latest' }}
$switchName = 'RUNNER'
$switchValue = 'self-hosted'

# GitHub-hosted list prices in USD per minute for standard runners (since 2026-01-01).
# Source: https://docs.github.com/en/billing/reference/actions-runner-pricing
$listPrice = @{ 'GitHub Linux' = 0.006; 'GitHub Windows' = 0.010; 'GitHub macOS' = 0.062 }

function Get-Setting([string]$Name) {
    if (-not (Test-Path $envFile)) { return $null }
    $line = Get-Content $envFile |
        Where-Object { $_ -match "^\s*$Name\s*=" } |
        Select-Object -First 1
    if (-not $line) { return $null }
    $value = ($line -replace "^\s*$Name\s*=\s*", '').Trim().Trim('"').Trim("'")
    if ($value) { $value } else { $null }
}

# Reads the GitHub token from 1Password. The token is never written to disk.
function Get-Token {
    if (-not (Test-Path $envFile)) {
        throw "Missing .env. Copy .env.example to .env and set TOKEN_REF."
    }
    $ref = Get-Setting 'TOKEN_REF'
    if (-not $ref -or $ref -notlike 'op://*') {
        throw "TOKEN_REF in .env must be a 1Password secret reference (op://vault/item/field). Plain tokens are not supported."
    }
    if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        throw "The 1Password CLI ('op') is not installed. Install it with: winget install AgileBits.1Password.CLI"
    }
    $token = op read $ref
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "1Password could not read TOKEN_REF. Check the reference and that 1Password is unlocked."
    }
    $token.Trim()
}

function Invoke-GitHub([string]$Path, [string]$Token, [string]$Method = 'Get', $Body = $null) {
    $request = @{
        Uri                = "https://api.github.com$Path"
        Method             = $Method
        SkipHttpErrorCheck = $true
        Headers            = @{
            Authorization          = "Bearer $Token"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'deskrunner'
        }
    }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Compress
        $request.ContentType = 'application/json'
    }
    Invoke-WebRequest @request
}

# Refuses public repos: a fork pull request could run any code on this PC.
function Assert-PrivateRepo([string]$Repo, [string]$Token) {
    $response = Invoke-GitHub "/repos/$Repo" $Token
    if ($response.StatusCode -eq 404) {
        throw "GitHub returned 404 for '$Repo'. The repo does not exist or the token cannot see it."
    }
    if ($response.StatusCode -ne 200) {
        throw "GitHub returned $($response.StatusCode) for '$Repo'. Check the token."
    }
    $info = $response.Content | ConvertFrom-Json
    if (-not $info.private) {
        throw "'$Repo' is public. deskrunner only runs for private repos, with no override."
    }
}

# --- Fallback switch -------------------------------------------------------
# start sets the repo variable so workflows run here; stop deletes it so they
# fall back to GitHub-hosted runners. Both return a short result word.

function Enable-RunnerSwitch([string]$Repo, [string]$Token, [string]$Name = $switchName, [string]$Value = $switchValue) {
    $base = "/repos/$Repo/actions/variables"
    $current = Invoke-GitHub "$base/$Name" $Token
    if ($current.StatusCode -eq 200) {
        $existing = ($current.Content | ConvertFrom-Json).value
        if ($existing -eq $Value) { return 'already-set' }
        # Someone chose another value on purpose (custom labels): leave it alone.
        return "kept:$existing"
    }
    if ($current.StatusCode -ne 404) { return "failed:$($current.StatusCode)" }
    $created = Invoke-GitHub $base $Token 'Post' @{ name = $Name; value = $Value }
    if ($created.StatusCode -eq 201) { 'set' } else { "failed:$($created.StatusCode)" }
}

function Disable-RunnerSwitch([string]$Repo, [string]$Token, [string]$Name = $switchName, [string]$Value = $switchValue) {
    $base = "/repos/$Repo/actions/variables"
    $current = Invoke-GitHub "$base/$Name" $Token
    if ($current.StatusCode -eq 404) { return 'not-set' }
    if ($current.StatusCode -ne 200) { return "failed:$($current.StatusCode)" }
    $existing = ($current.Content | ConvertFrom-Json).value
    # Only delete the value deskrunner sets.
    if ($existing -ne $Value) { return "kept:$existing" }
    $deleted = Invoke-GitHub "$base/$Name" $Token 'Delete'
    if ($deleted.StatusCode -eq 204) { 'deleted' } else { "failed:$($deleted.StatusCode)" }
}

function Write-SwitchResult([string]$Result, [string]$Repo) {
    $manual = "The token needs the 'repo' scope (classic) or 'Variables: Read and write' (fine-grained)."
    switch -Wildcard ($Result) {
        'set'         { Write-Host "Set variable $switchName=$switchValue on $Repo. Workflows that read vars.$switchName now run here." }
        'already-set' { Write-Host "Variable $switchName is already $switchValue on $Repo." }
        'deleted'     { Write-Host "Deleted variable $switchName on $Repo. Workflows fall back to GitHub-hosted runners." }
        'not-set'     { Write-Host "Variable $switchName was not set on $Repo." }
        'kept:*'      { Write-Host "Variable $switchName on $Repo has a custom value ('$($Result.Substring(5))'); left unchanged." }
        'failed:*'    { Write-Warning "Could not change variable $switchName on $Repo (HTTP $($Result.Substring(7))). $manual" }
    }
}

# --- init ------------------------------------------------------------------
# Rewrites `runs-on: ubuntu-*` in a checkout's workflows to the switchable form.

function Invoke-Init([string]$Path, [bool]$Preview) {
    $root = if ($Path) { $Path } else { (Get-Location).Path }
    $workflowDir = Join-Path $root '.github' 'workflows'
    if (-not (Test-Path $workflowDir)) {
        throw "No .github\workflows folder in '$root'. Run init inside a repo checkout, or pass its path."
    }
    $files = @(Get-ChildItem $workflowDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' })
    if ($files.Count -eq 0) { throw "No workflow files in '$workflowDir'." }

    $convertPattern = '^(\s*runs-on:\s*)([''"]?)(ubuntu-latest|ubuntu-\d\d\.\d\d)\2(\s+#.*)?\s*$'
    $converted = 0; $changedFiles = 0; $cacheJobs = 0; $noConcurrency = @()
    $utf8 = [System.Text.UTF8Encoding]::new($false)

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = $text -split '\r?\n'

        # A small line parser: find each job under `jobs:` and its direct keys.
        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        $inJobs = $false; $jobIndent = -1; $job = $null; $hasConcurrency = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*(#.*)?$') { continue }
            $indent = $line.Length - $line.TrimStart().Length
            if ($indent -eq 0) {
                $inJobs = $line -match '^jobs:\s*(#.*)?$'
                if ($line -match '^concurrency:') { $hasConcurrency = $true }
                $job = $null
                continue
            }
            if (-not $inJobs) { continue }
            if ($jobIndent -lt 0) { $jobIndent = $indent }
            if ($indent -eq $jobIndent) {
                $job = $null
                if ($line -match '^\s*[''"]?([^''":#]+)[''"]?:') {
                    $job = @{ Name = $Matches[1].Trim(); KeyIndent = -1; RunsOn = -1; Blockers = @(); Cache = $false }
                    $jobs.Add($job)
                }
                continue
            }
            if (-not $job) { continue }
            if ($line -match 'uses:\s*[''"]?actions/cache(/restore|/save)?@') { $job.Cache = $true }
            if ($job.KeyIndent -lt 0) { $job.KeyIndent = $indent }
            if ($indent -ne $job.KeyIndent) { continue }
            if ($line -match '^\s*runs-on:') { $job.RunsOn = $i }
            elseif ($line -match '^\s*(container|services):') { $job.Blockers += $Matches[1] }
        }

        $report = @(); $fileChanged = $false
        foreach ($job in $jobs) {
            if ($job.RunsOn -lt 0) { continue }   # reusable workflow call: nothing to change
            $line = $lines[$job.RunsOn]
            $value = (($line -replace '^\s*runs-on:\s*', '') -replace '\s+#.*$', '').Trim()
            if ($value -match 'vars\.RUNNER') {
                $report += "  = $($job.Name): already switchable"
            } elseif ($job.Blockers.Count -gt 0) {
                $report += "  ! $($job.Name): left on GitHub, it uses $($job.Blockers -join ' and ') (unreliable on deskrunner)"
            } elseif ($line -match $convertPattern) {
                $lines[$job.RunsOn] = $Matches[1] + '${{ vars.RUNNER || ''' + $Matches[3] + ''' }}' + $Matches[4]
                $fileChanged = $true; $converted++
                $note = ''
                if ($job.Cache) { $note = ' (uses actions/cache)'; $cacheJobs++ }
                $report += "  + $($job.Name): $value -> switchable$note"
            } elseif ($value -match 'windows|macos') {
                $report += "  - $($job.Name): stays on GitHub ($value); deskrunner only provides Linux"
            } else {
                $report += "  ? $($job.Name): not changed, edit by hand (runs-on: $value)"
            }
        }

        if ($report.Count -eq 0) { continue }
        Write-Host $file.Name
        $report | ForEach-Object { Write-Host $_ }
        if ($fileChanged) {
            $changedFiles++
            if (-not $hasConcurrency) { $noConcurrency += $file.Name }
            if (-not $Preview) {
                [System.IO.File]::WriteAllText($file.FullName, ($lines -join $newline), $utf8)
            }
        }
    }

    Write-Host ''
    if ($converted -eq 0) {
        Write-Host 'Nothing to change.'
        return
    }
    $verb = if ($Preview) { 'Would change' } else { 'Changed' }
    Write-Host "$verb $converted job(s) in $changedFiles file(s)."
    if ($cacheJobs -gt 0) {
        Write-Host "$cacheJobs converted job(s) use actions/cache. pnpm, npm, uv and pip caches already persist on deskrunner, so those steps can go."
    }
    if ($noConcurrency.Count -gt 0) {
        Write-Host "No top-level 'concurrency:' in: $($noConcurrency -join ', '). Add one so superseded pushes are cancelled (see README)."
    }
    Write-Host 'The image is leaner than ubuntu-latest: make sure each job installs its tools with setup-* actions.'
    if ($Preview) {
        Write-Host "`nDry run: no files were written. Run again without -DryRun to apply."
    } else {
        Write-Host "`nNext: review with 'git diff', commit and merge. Then run: deskrunner.ps1 start <owner/repo>"
    }
}

# --- savings ---------------------------------------------------------------
# Reads job history and shows billable minutes per workflow and runner type.

function Invoke-Savings([string]$Repo, [string]$Token, [int]$Days) {
    $today = (Get-Date).ToUniversalTime().Date
    $since = $today.AddDays(-$Days)

    # The runs API returns at most 1,000 results per query, so ask in 5-day windows.
    $runs = @{}
    for ($start = $since; $start -le $today; $start = $start.AddDays(5)) {
        $range = '{0:yyyy-MM-dd}..{1:yyyy-MM-dd}' -f $start, $start.AddDays(4)
        $page = 1
        do {
            $response = Invoke-GitHub "/repos/$Repo/actions/runs?created=$range&per_page=100&page=$page" $Token
            if ($response.StatusCode -ne 200) {
                throw "GitHub returned $($response.StatusCode) when listing runs for '$Repo'. The token needs the ``repo`` scope (classic) or 'Actions: Read' (fine-grained)."
            }
            $data = $response.Content | ConvertFrom-Json
            if ($page -eq 1 -and $data.total_count -gt 1000) {
                Write-Warning "More than 1,000 runs between $range; the totals will be too low."
            }
            foreach ($run in $data.workflow_runs) {
                $runs[$run.id] = [pscustomobject]@{
                    # Dependabot names each run "... #123456"; drop the number so they group.
                    Name    = $run.name -replace '\s+#\d+$', ''
                    # Runs GitHub creates itself (Dependabot and similar) have no workflow file.
                    Managed = $run.path -like 'dynamic/*'
                }
            }
            $page++
        } while ($data.workflow_runs.Count -eq 100 -and $page -le 10)
    }

    if ($runs.Count -eq 0) {
        Write-Host "No workflow runs for $Repo in the last $Days days."
        return
    }
    Write-Host "Reading jobs for $($runs.Count) runs..."

    $jobs = $runs.GetEnumerator() | ForEach-Object -ThrottleLimit 8 -Parallel {
        $token = $using:Token
        $repo = $using:Repo
        $headers = @{
            Authorization          = "Bearer $token"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'deskrunner'
        }
        $page = 1
        do {
            $uri = "https://api.github.com/repos/$repo/actions/runs/$($_.Key)/jobs?filter=all&per_page=100&page=$page"
            $response = Invoke-WebRequest -Uri $uri -Headers $headers -SkipHttpErrorCheck
            if ($response.StatusCode -ne 200) { break }
            $data = $response.Content | ConvertFrom-Json
            foreach ($job in $data.jobs) {
                [pscustomobject]@{
                    Workflow   = $_.Value.Name
                    Managed    = $_.Value.Managed
                    Labels     = @($job.labels)
                    Started    = $job.started_at
                    Completed  = $job.completed_at
                    Conclusion = $job.conclusion
                }
            }
            $page++
        } while ($data.jobs.Count -eq 100)
    }

    $rows = foreach ($job in $jobs) {
        if (-not $job.Started -or -not $job.Completed -or $job.Conclusion -eq 'skipped') { continue }
        $seconds = ([datetime]$job.Completed - [datetime]$job.Started).TotalSeconds
        if ($seconds -le 0) { continue }
        $labels = ($job.Labels -join ' ').ToLower()
        $kind = if ($job.Managed) { 'GitHub-managed' }
                elseif ($labels -match 'self-hosted') { 'Self-hosted' }
                elseif ($labels -match 'windows') { 'GitHub Windows' }
                elseif ($labels -match 'macos') { 'GitHub macOS' }
                else { 'GitHub Linux' }
        # GitHub bills each job rounded up to the next full minute.
        [pscustomobject]@{ Workflow = $job.Workflow; Runner = $kind; Minutes = [int][math]::Ceiling($seconds / 60) }
    }
    $rows = @($rows)
    if ($rows.Count -eq 0) {
        Write-Host "No finished jobs for $Repo in the last $Days days."
        return
    }

    # Fixed number format, whatever the Windows region settings are.
    $plain = [cultureinfo]::InvariantCulture
    function Format-Usd([double]$Amount) { [string]::Format($plain, '${0:N2}', $Amount) }
    function Format-Price([string]$Kind, [double]$Minutes) {
        if ($listPrice.ContainsKey($Kind)) { Format-Usd ($Minutes * $listPrice[$Kind]) } else { '-' }
    }
    function Format-Minutes([double]$Minutes) { [string]::Format($plain, '{0:N0}', $Minutes) }

    Write-Host "`nActions usage for $Repo, last $Days days: $($runs.Count) runs, $($rows.Count) jobs"
    $table = $rows | Group-Object Workflow, Runner | ForEach-Object {
        $minutes = ($_.Group | Measure-Object Minutes -Sum).Sum
        [pscustomobject]@{
            Workflow     = $_.Group[0].Workflow
            Runner       = $_.Group[0].Runner
            Jobs         = $_.Count
            Minutes      = [int]$minutes
            'List price' = Format-Price $_.Group[0].Runner $minutes
        }
    } | Sort-Object Minutes -Descending
    ($table | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host

    $total = @{}
    foreach ($row in $rows) { $total[$row.Runner] += $row.Minutes }
    $linux = [int]$total['GitHub Linux']; $windows = [int]$total['GitHub Windows']
    $mac = [int]$total['GitHub macOS']; $self = [int]$total['Self-hosted']
    $managed = [int]$total['GitHub-managed']

    Write-Host ''
    Write-Host "Can move to deskrunner (GitHub Linux): $(Format-Minutes $linux) min, $(Format-Price 'GitHub Linux' $linux) at list price"
    if ($windows + $mac -gt 0) {
        $stays = ($windows * $listPrice['GitHub Windows']) + ($mac * $listPrice['GitHub macOS'])
        Write-Host "Stays on GitHub (Windows and macOS):   $(Format-Minutes ($windows + $mac)) min, $(Format-Usd $stays) at list price"
    }
    if ($self -gt 0) {
        Write-Host "Already self-hosted:                   $(Format-Minutes $self) min, worth $(Format-Price 'GitHub Linux' $self) on GitHub Linux"
    }
    if ($managed -gt 0) {
        Write-Host "GitHub-managed (Dependabot and similar): $(Format-Minutes $managed) min, cannot be moved with runs-on"
    }
    Write-Host "`nList price is for standard runners and ignores your plan's free minutes, so the real bill can be lower."
}

# --- doctor ----------------------------------------------------------------

function Invoke-Doctor {
    $failed = 0
    function Report([bool]$Ok, [string]$Text, [string]$Fix) {
        if ($Ok) {
            Write-Host "[ok]   $Text"
        } else {
            Write-Host "[fail] $Text"
            if ($Fix) { Write-Host "       Fix: $Fix" }
            Set-Variable -Name failed -Value ($failed + 1) -Scope 1
        }
    }

    Report $true "PowerShell $($PSVersionTable.PSVersion) on Windows"

    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    Report ([bool]$dockerCmd) "Docker CLI: $($dockerCmd.Source)" 'Install Docker Desktop.'
    if ($dockerCmd) {
        $server = docker info --format '{{.ServerVersion}} ({{.OperatingSystem}})' 2>$null
        $engineUp = ($LASTEXITCODE -eq 0 -and $server)
        Report $engineUp "Docker engine: $server" 'Start Docker Desktop and wait until the engine is running.'
    }

    $opCmd = Get-Command op -ErrorAction SilentlyContinue
    Report ([bool]$opCmd) "1Password CLI: $($opCmd.Source)" 'winget install AgileBits.1Password.CLI'

    $hasEnv = Test-Path $envFile
    Report $hasEnv ".env file: $envFile" 'Copy .env.example to .env.'
    $ref = Get-Setting 'TOKEN_REF'
    $refOk = ($ref -like 'op://*')
    Report $refOk 'TOKEN_REF is a 1Password reference' 'Set TOKEN_REF=op://<vault-id>/<item-id>/<field> in .env.'

    if ($opCmd -and $refOk) {
        $token = $null
        try { $token = Get-Token } catch { Report $false '1Password read' $_.Exception.Message }
        if ($token) {
            Report $true '1Password read: token received'
            $response = Invoke-GitHub '/user' $token
            if ($response.StatusCode -eq 200) {
                $login = ($response.Content | ConvertFrom-Json).login
                $scopes = "$($response.Headers['X-OAuth-Scopes'])"
                if ($scopes) {
                    Report $true "GitHub token: valid for '$login', scopes: $scopes"
                    $list = $scopes -split ',\s*'
                    Report ($list -contains 'repo') 'Scope for repo runners (repo)' 'Add the `repo` scope to the token.'
                    Report ($list -contains 'admin:org') 'Scope for org runners (admin:org)' 'Add `admin:org` if you use org targets.'
                } else {
                    Report $true "GitHub token: valid for '$login' (fine-grained token; GitHub does not list its permissions)"
                }
            } else {
                Report $false "GitHub token: rejected with HTTP $($response.StatusCode)" 'Create a new token and update the 1Password item.'
            }
        }
    }

    if ($failed -gt 0) {
        Write-Host "`n$failed check(s) failed."
        exit 1
    }
    Write-Host "`nAll checks passed."
    exit 0
}

# --- main ------------------------------------------------------------------

if ($Action -eq 'doctor') { Invoke-Doctor }

if ($Action -eq 'init') {
    Invoke-Init $Target $DryRun.IsPresent
    exit 0
}

if ($Action -eq 'status') {
    docker ps -a --filter "label=com.docker.compose.project" --filter "name=^$projectPrefix" `
        --format 'table {{.Label "com.docker.compose.project"}}\t{{.Names}}\t{{.Status}}'
    exit $LASTEXITCODE
}

if ($Action -eq 'update') {
    docker compose -f $composeFile pull
    Write-Host "Image updated. Run 'restart <target>' for each running target to apply it."
    exit $LASTEXITCODE
}

if (-not $Target) { $Target = Get-Setting 'DEFAULT_TARGET' }
if (-not $Target) { throw "No org or owner/repo given, and DEFAULT_TARGET is not set in .env." }
if ($Target -notmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$') {
    throw "'$Target' is not an org name or owner/repo."
}
$isRepo = $Target -match '/'

if ($Action -eq 'savings') {
    if (-not $isRepo) { throw "savings needs a repo target (owner/repo)." }
    Invoke-Savings $Target (Get-Token) $Days
    exit 0
}

if ($isRepo) {
    # owner/repo: the runner serves that one repo (the only option for personal accounts).
    $env:RUNNER_SCOPE = 'repo'
    $env:REPO_URL = "https://github.com/$Target"
    $env:ORG_NAME = ''
} else {
    $env:RUNNER_SCOPE = 'org'
    $env:ORG_NAME = $Target
    $env:REPO_URL = ''
}

# The fallback switch only works for repo targets.
$useSwitch = $isRepo -and -not $NoSwitch
$token = $null

if ($Action -in 'start', 'restart') {
    $token = Get-Token
    if ($isRepo) { Assert-PrivateRepo $Target $token }
    $env:ACCESS_TOKEN = $token
} else {
    # stop and logs do not need the token for Docker; compose only needs the variable to exist.
    $env:ACCESS_TOKEN = 'unused'
}

$project = $projectPrefix + ($Target.ToLower() -replace '[^a-z0-9_-]', '-')
$compose = @('compose', '-p', $project, '-f', $composeFile)
if ($Docker) {
    $compose += @('-f', $composeDockerFile)
    # Only runners that can reach Docker advertise the `docker` label.
    $env:RUNNER_LABELS = 'deskrunner,docker'
} else {
    $env:RUNNER_LABELS = 'deskrunner'
}

try {
    if ($Action -eq 'stop' -and $useSwitch) {
        # Send new jobs back to GitHub before the runners go away.
        try {
            $token = Get-Token
            Write-SwitchResult (Disable-RunnerSwitch $Target $token) $Target
        } catch {
            Write-Warning "Could not delete variable $switchName on ${Target}: $($_.Exception.Message) Jobs will wait for a runner until you delete it: gh variable delete $switchName --repo $Target"
        }
    }

    switch ($Action) {
        'start'   { docker @compose up -d --scale "runner=$Count" }
        # down, not stop: the runner deregisters from GitHub on exit, so the next
        # start must be a fresh container. Caches live in named volumes and survive.
        'stop'    { docker @compose down }
        'restart' { docker @compose up -d --force-recreate --scale "runner=$Count" }
        'logs'    { docker @compose logs -f --tail 100 }
    }
    $code = $LASTEXITCODE

    if ($Action -in 'start', 'restart' -and $code -eq 0) {
        if ($useSwitch) {
            Write-SwitchResult (Enable-RunnerSwitch $Target $token) $Target
        } elseif (-not $isRepo) {
            Write-Host "Org target: set the $switchName variable yourself, per repo or for the org (gh variable set $switchName --body $switchValue)."
        }
    }
} finally {
    # Do not leave the token in this PowerShell session.
    Remove-Item Env:ACCESS_TOKEN -ErrorAction SilentlyContinue
}
exit $code
