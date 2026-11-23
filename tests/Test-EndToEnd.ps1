# End-to-end test: runs the whole task (run.js -> sf-delta.ps1) against a temporary git
# repository with a fake `sf` CLI, so no Salesforce org is touched.
#
# Run:  powershell -NoProfile -File tests/Test-EndToEnd.ps1 [-BaselineRef <git ref>]
#
# With -BaselineRef the same scenarios also run against the task script from that ref.
# Scenarios without Flow deletions must then produce identical `sf` calls.

param([string]$BaselineRef = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$taskRel = 'buildAndReleaseTasks/SfOrgValidateDeploy'
$currentTask = Join-Path $repoRoot $taskRel

$work = Join-Path ([IO.Path]::GetTempPath()) ('sfdelta-e2e-' + [guid]::NewGuid().ToString('N'))
$bin = Join-Path $work 'bin'
$sandbox = Join-Path $work 'sandbox'
$sourcesDir = Join-Path $work 'sources'
$fixtures = Join-Path $work 'fixtures'
New-Item -ItemType Directory -Force -Path $bin, $sandbox, "$sandbox\local", "$sandbox\tmp", $sourcesDir, $fixtures | Out-Null

Copy-Item (Join-Path $PSScriptRoot 'e2e\fake-sf.js') (Join-Path $bin 'fake-sf.js')
[IO.File]::WriteAllText((Join-Path $bin 'sf.cmd'), "@echo off`r`nnode `"%~dp0fake-sf.js`" %*`r`n")

# The task allow-lists plugins in the user's sf config. Snapshot the real files so they can be restored.
$realConfigs = @(
    (Join-Path $HOME '.config\sf\unsignedPluginAllowList.json'),
    (Join-Path $env:LOCALAPPDATA 'sf\unsignedPluginAllowList.json')
)
$snapshots = @{}
foreach ($c in $realConfigs) { $snapshots[$c] = if (Test-Path $c) { , [IO.File]::ReadAllBytes($c) } else { $null } }

$baselineTask = $null
if ($BaselineRef) {
    $baselineTask = Join-Path $work 'baseline-task'
    New-Item -ItemType Directory -Force -Path $baselineTask | Out-Null
    foreach ($f in 'run.js', 'sf-delta.ps1') {
        $content = & git -C $repoRoot show "${BaselineRef}:$taskRel/$f"
        if ($LASTEXITCODE -ne 0) { throw "Cannot read $f at $BaselineRef" }
        [IO.File]::WriteAllText((Join-Path $baselineTask $f), (($content -join "`n") + "`n"))
    }
}

# ---- git repo with two commits ------------------------------------------------
Push-Location $sourcesDir
& git init -q . 2>&1 | Out-Null
& git config user.email 'test@example.com'
& git config user.name 'test'
& git config core.autocrlf false
New-Item -ItemType Directory -Force -Path 'force-app' | Out-Null
Set-Content -Path 'force-app/a.txt' -Value 'one'
& git add -A; & git commit -q -m 'first'
Set-Content -Path 'force-app/a.txt' -Value 'two'
& git add -A; & git commit -q -m 'second'
Pop-Location

# ---- fixtures -----------------------------------------------------------------
$hdr = '<?xml version="1.0" encoding="UTF-8"?>' + "`n" + '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' + "`n"
function Write-Fixture([string]$name, [string]$body) {
    $p = Join-Path $fixtures $name
    [IO.File]::WriteAllText($p, $hdr + $body + "    <version>64.0</version>`n</Package>`n")
    return $p
}
$pkgApex = Write-Fixture 'pkg-apex.xml' "    <types>`n        <members>MyClass</members>`n        <name>ApexClass</name>`n    </types>`n"
$pkgEmpty = Write-Fixture 'pkg-empty.xml' ''
$destFlow = Write-Fixture 'dest-flow.xml' "    <types>`n        <members>Account_Flow</members>`n        <name>Flow</name>`n    </types>`n    <types>`n        <members>OldClass</members>`n        <name>ApexClass</name>`n    </types>`n"
$destFlowOnly = Write-Fixture 'dest-flow-only.xml' "    <types>`n        <members>Gone_Flow</members>`n        <name>Flow</name>`n    </types>`n"
$destApexOnly = Write-Fixture 'dest-apex.xml' "    <types>`n        <members>OldClass</members>`n        <name>ApexClass</name>`n    </types>`n"
$destEmpty = Write-Fixture 'dest-empty.xml' ''

# ---- runner -------------------------------------------------------------------
function Invoke-Task {
    param([string]$TaskDir, [hashtable]$Env)
    $log = Join-Path $work ('sf-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    & git -C $sourcesDir clean -fdxq 2>&1 | Out-Null

    $base = @{
        PATH = "$bin;$env:PATH"; SF_FAKE_LOG = $log
        USERPROFILE = $sandbox; HOME = $sandbox; LOCALAPPDATA = "$sandbox\local"
        TEMP = "$sandbox\tmp"; TMP = "$sandbox\tmp"; AGENT_TEMPDIRECTORY = "$sandbox\tmp"
        BUILD_SOURCESDIRECTORY = $sourcesDir
        INPUT_ALIAS = 'qa'; INPUT_AUTHMETHOD = 'authUrl'; INPUT_SFDX_AUTH_URL = 'force://fake-token'
        INPUT_SKIPINSTALLSFCLI = 'true'; INPUT_VALIDATETESTLEVEL = 'NoTestRun'; INPUT_DEPLOYTESTLEVEL = 'NoTestRun'
        INPUT_TARGETBRANCH = 'main'; INPUT_PUBLISHDELTAARTIFACT = 'true'; INPUT_DELTAARTIFACTNAME = 'Delta-Package'
        INPUT_DEPLOYWAITTIME = '120'; INPUT_IGNORECONFLICTS = 'true'; INPUT_ORGTYPE = 'sandbox'
    }
    foreach ($k in $Env.Keys) { $base[$k] = $Env[$k] }

    $names = @('SF_FAKE_PACKAGE', 'SF_FAKE_DESTRUCTIVE', 'SF_FAKE_FLOWS', 'SF_FAKE_QUERY_FAIL', 'SF_FAKE_DEPLOY_EXIT',
        'INPUT_OPERATIONMODE', 'BUILD_REASON', 'BUILD_SOURCEBRANCH', 'SYSTEM_PULLREQUEST_TARGETBRANCH', 'SYSTEM_PULLREQUEST_PULLREQUESTID')
    $saved = @{}
    foreach ($k in (@($base.Keys) + $names | Select-Object -Unique)) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        $value = if ($base.ContainsKey($k)) { [string]$base[$k] } else { $null }
        [Environment]::SetEnvironmentVariable($k, $value)
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # Run from the temp folder so PowerShell cache files never land in the repository.
    Push-Location $work
    try {
        $out = (& node (Join-Path $TaskDir 'run.js') 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $previous
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }

    $calls = @()
    if (Test-Path $log) { $calls = @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json }) }
    $dest = Join-Path $sourcesDir 'destructiveChanges/destructiveChanges.xml'
    $artifacts = @()
    if (Test-Path (Join-Path $sourcesDir 'artifacts')) { $artifacts = @(Get-ChildItem (Join-Path $sourcesDir 'artifacts') | ForEach-Object { $_.Name }) }
    return [pscustomobject]@{
        Exit = $code; Output = $out; Calls = $calls
        Destructive = $(if (Test-Path $dest) { [IO.File]::ReadAllText($dest) } else { $null })
        Artifacts = $artifacts
    }
}
# Callers must wrap these in @(...) so zero or one match still behaves as an array.
function Get-DeployCalls($r) { return $r.Calls | Where-Object { @($_.argv).Count -ge 3 -and $_.argv[0] -eq 'project' -and $_.argv[1] -eq 'deploy' -and $_.argv[2] -eq 'start' } }
function Get-QueryCalls($r) { return $r.Calls | Where-Object { @($_.argv).Count -ge 2 -and $_.argv[0] -eq 'data' -and $_.argv[1] -eq 'query' } }
function Get-OutputTail($r) { return (@($r.Output -split "`n") | Select-Object -Last 25) -join "`n" }
function Get-CallSignature($r) { return (@($r.Calls | ForEach-Object { $_.argv -join ' ' }) -join "`n") }
function Get-ManifestArg($call) {
    $i = [array]::IndexOf($call.argv, '--post-destructive-changes')
    if ($i -lt 0) { return $null }
    return $call.argv[$i + 1]
}

$script:passed = 0
$script:failed = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:passed++; Write-Host "  PASS  $Name" }
    else { $script:failed++; Write-Host "  FAIL  $Name $Detail" }
}
function Assert-SameAsBaseline {
    param([string]$Label, [hashtable]$Env, $Current)
    if (-not $baselineTask) { return }
    $old = Invoke-Task $baselineTask $Env
    Assert-That "${Label}: sf calls identical to $BaselineRef" ((Get-CallSignature $old) -eq (Get-CallSignature $Current)) "`n--- baseline`n$(Get-CallSignature $old)`n--- current`n$(Get-CallSignature $Current)"
    Assert-That "${Label}: exit code identical to $BaselineRef" ($old.Exit -eq $Current.Exit)
}

$flows = '{"Account_Flow":[1,2,3]}'

try {
    Write-Host 'A. validate: manifests are printed and an active flow is expanded to all versions'
    $envA = @{ INPUT_OPERATIONMODE = 'validate'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destFlow; SF_FAKE_FLOWS = $flows }
    $r = Invoke-Task $currentTask $envA
    $d = @(Get-DeployCalls $r)
    $q = @(Get-QueryCalls $r)
    Assert-That 'task exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)`n$(Get-OutputTail $r)"
    $bannerIdx = $r.Output.IndexOf('Delta package generated.')
    Assert-That 'banner "Delta package generated." is shown' ($bannerIdx -ge 0)
    Assert-That 'package.xml contents printed after the banner' ($r.Output.IndexOf('<members>MyClass</members>') -gt $bannerIdx)
    Assert-That 'destructiveChanges.xml contents printed after the banner' ($r.Output.IndexOf('<members>Account_Flow</members>') -gt $bannerIdx)
    Assert-That 'exactly one Tooling API flow query' ($q.Count -eq 1)
    Assert-That 'query targets the org alias with --use-tooling-api' ($q.Count -eq 1 -and $q[0].argv -contains '--use-tooling-api' -and $q[0].argv -contains 'qa')
    Assert-That 'destructive file lists Account_Flow-1, -2, -3' ($r.Destructive -match '<members>Account_Flow-1</members>' -and $r.Destructive -match '<members>Account_Flow-2</members>' -and $r.Destructive -match '<members>Account_Flow-3</members>' -and $r.Destructive -notmatch '<members>Account_Flow</members>')
    Assert-That 'other deletions are kept' ($r.Destructive -match '<members>OldClass</members>')
    Assert-That 'deploy start ran once, with --dry-run and the destructive manifest' ($d.Count -eq 1 -and $d[0].argv -contains '--dry-run' -and $null -ne (Get-ManifestArg $d[0]))
    Assert-That 'flow expansion ran before the deploy call' ($q.Count -eq 1 -and $d.Count -eq 1 -and $r.Calls.IndexOf($q[0]) -lt $r.Calls.IndexOf($d[0]))
    Assert-That 'expanded manifest printed' ($r.Output -match 'after Flow version expansion')
    Assert-That 'Validation succeeded banner' ($r.Output -match 'Validation succeeded\.')
    Assert-That 'artifacts hold the delta manifest and the expanded manifest' (@($r.Artifacts | Where-Object { $_ -like 'destructiveChanges_flow-versions_*' }).Count -eq 1 -and @($r.Artifacts | Where-Object { $_ -like 'package_*' }).Count -eq 1)
    Assert-That 'artifacts published' ($r.Output -match '##vso\[artifact\.upload')

    Write-Host 'B. deploy: same expansion, real deploy flags'
    $r = Invoke-Task $currentTask @{ INPUT_OPERATIONMODE = 'deploy'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destFlow; SF_FAKE_FLOWS = $flows }
    $d = @(Get-DeployCalls $r)
    Assert-That 'task exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)`n$(Get-OutputTail $r)"
    Assert-That 'deploy start has no --dry-run and has --ignore-conflicts' ($d.Count -eq 1 -and $d[0].argv -notcontains '--dry-run' -and $d[0].argv -contains '--ignore-conflicts')
    Assert-That 'destructive file lists every version' ($r.Destructive -match 'Account_Flow-3')
    Assert-That 'Deployment succeeded banner' ($r.Output -match 'Deployment succeeded\.')

    Write-Host 'C. validate, deletions without flows: nothing changes'
    $envC = @{ INPUT_OPERATIONMODE = 'validate'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destApexOnly }
    $r = Invoke-Task $currentTask $envC
    Assert-That 'task exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)`n$(Get-OutputTail $r)"
    Assert-That 'no flow query is made' (@(Get-QueryCalls $r).Count -eq 0)
    Assert-That 'destructive manifest is passed unchanged' ($r.Destructive -eq [IO.File]::ReadAllText($destApexOnly))
    Assert-That 'no expanded artifact is created' (@($r.Artifacts | Where-Object { $_ -like '*flow-versions*' }).Count -eq 0)
    Assert-SameAsBaseline 'C' $envC $r

    Write-Host 'D. validate, no destructiveChanges.xml generated'
    $envD = @{ INPUT_OPERATIONMODE = 'validate'; SF_FAKE_PACKAGE = $pkgApex }
    $r = Invoke-Task $currentTask $envD
    Assert-That 'task exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)`n$(Get-OutputTail $r)"
    Assert-That 'log says there are no deletions' ($r.Output -match 'no deletions')
    Assert-That 'deploy start ran without a destructive manifest' (@(Get-DeployCalls $r).Count -eq 1 -and $null -eq (Get-ManifestArg @(Get-DeployCalls $r)[0]))
    Assert-SameAsBaseline 'D' $envD $r

    Write-Host 'E. empty destructiveChanges.xml (no types)'
    $envE = @{ INPUT_OPERATIONMODE = 'deploy'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destEmpty }
    $r = Invoke-Task $currentTask $envE
    Assert-That 'task exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)`n$(Get-OutputTail $r)"
    Assert-That 'no flow query is made' (@(Get-QueryCalls $r).Count -eq 0)
    Assert-SameAsBaseline 'E' $envE $r

    Write-Host 'F. only a flow that is already gone from the org, empty package: nothing to validate'
    $r = Invoke-Task $currentTask @{ INPUT_OPERATIONMODE = 'validate'; SF_FAKE_PACKAGE = $pkgEmpty; SF_FAKE_DESTRUCTIVE = $destFlowOnly; SF_FAKE_FLOWS = '{}' }
    Assert-That 'task exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)`n$(Get-OutputTail $r)"
    Assert-That 'no deploy start call' (@(Get-DeployCalls $r).Count -eq 0)
    Assert-That 'banner explains nothing remains' ($r.Output -match 'No components remain after Flow version expansion')
    Assert-That 'delta artifacts are still published' ($r.Output -match '##vso\[artifact\.upload')

    Write-Host 'G. gone flow plus a real change in package.xml: validation still runs'
    $r = Invoke-Task $currentTask @{ INPUT_OPERATIONMODE = 'validate'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destFlowOnly; SF_FAKE_FLOWS = '{}' }
    Assert-That 'task exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)`n$(Get-OutputTail $r)"
    Assert-That 'deploy start ran once' (@(Get-DeployCalls $r).Count -eq 1)
    Assert-That 'the Flow type is gone from the manifest that is passed' ($r.Destructive -notmatch '<name>Flow</name>' -and $r.Destructive -notmatch '<types>')

    Write-Host 'H. flow query fails: the task fails before deploying and still publishes artifacts'
    $r = Invoke-Task $currentTask @{ INPUT_OPERATIONMODE = 'validate'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destFlow; SF_FAKE_QUERY_FAIL = '1' }
    Assert-That 'task fails' ($r.Exit -ne 0)
    Assert-That 'error mentions the flow version query' ($r.Output -match 'Flow version query failed')
    Assert-That 'deploy start never ran' (@(Get-DeployCalls $r).Count -eq 0)
    Assert-That 'delta artifacts are still published' ($r.Output -match '##vso\[artifact\.upload')

    Write-Host 'I. deploy failure after expansion still fails the task'
    $r = Invoke-Task $currentTask @{ INPUT_OPERATIONMODE = 'deploy'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destFlow; SF_FAKE_FLOWS = $flows; SF_FAKE_DEPLOY_EXIT = '1' }
    Assert-That 'task fails' ($r.Exit -ne 0)
    Assert-That 'Deployment failed banner' ($r.Output -match 'Deployment failed\.')

    Write-Host 'J. operationMode auto keeps its branch rules'
    $envPr = @{ INPUT_OPERATIONMODE = 'auto'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destApexOnly; BUILD_REASON = 'PullRequest'; SYSTEM_PULLREQUEST_PULLREQUESTID = '12'; SYSTEM_PULLREQUEST_TARGETBRANCH = 'refs/heads/main'; BUILD_SOURCEBRANCH = 'refs/pull/12/merge' }
    $r = Invoke-Task $currentTask $envPr
    Assert-That 'PR into main validates (dry-run)' ($r.Exit -eq 0 -and @(Get-DeployCalls $r).Count -eq 1 -and @(Get-DeployCalls $r)[0].argv -contains '--dry-run')
    Assert-SameAsBaseline 'J-PR' $envPr $r
    $envMain = @{ INPUT_OPERATIONMODE = 'auto'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destApexOnly; BUILD_REASON = 'IndividualCI'; BUILD_SOURCEBRANCH = 'refs/heads/main' }
    $r = Invoke-Task $currentTask $envMain
    Assert-That 'CI on main deploys' ($r.Exit -eq 0 -and @(Get-DeployCalls $r).Count -eq 1 -and @(Get-DeployCalls $r)[0].argv -notcontains '--dry-run')
    Assert-SameAsBaseline 'J-main' $envMain $r
    $envOther = @{ INPUT_OPERATIONMODE = 'auto'; SF_FAKE_PACKAGE = $pkgApex; SF_FAKE_DESTRUCTIVE = $destApexOnly; BUILD_REASON = 'IndividualCI'; BUILD_SOURCEBRANCH = 'refs/heads/feature/x' }
    $r = Invoke-Task $currentTask $envOther
    Assert-That 'other branches skip without calling sf' ($r.Exit -eq 0 -and $r.Calls.Count -eq 0)
    Assert-SameAsBaseline 'J-other' $envOther $r
}
catch {
    Write-Host "SCENARIO ERROR: $_"
    $script:failed++
}
finally {
    foreach ($c in $realConfigs) {
        $now = if (Test-Path $c) { , [IO.File]::ReadAllBytes($c) } else { $null }
        $before = $snapshots[$c]
        $same = ($null -eq $now -and $null -eq $before) -or ($null -ne $now -and $null -ne $before -and [Convert]::ToBase64String($now) -eq [Convert]::ToBase64String($before))
        if (-not $same) {
            Write-Host "NOTE: restoring $c"
            if ($null -eq $before) { Remove-Item -LiteralPath $c -Force } else { [IO.File]::WriteAllBytes($c, $before) }
        }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $($script:passed)  Failed: $($script:failed)"
if ($script:failed -gt 0) { exit 1 }
exit 0
