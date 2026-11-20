#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TaskInput {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )
    $envKey = ('INPUT_{0}' -f ($Name.ToUpperInvariant() -replace '\.', '_' -replace '-', '_'))
    return [Environment]::GetEnvironmentVariable($envKey)
}

function Test-InputBool {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value -eq 'true'
}

function Get-NormalizedBranchName {
    param([string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return '' }
    return ($Ref -replace '^refs/heads/', '').Trim()
}

function Test-BranchNameEquals {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    return [string]::Equals($A.Trim(), $B.Trim(), [StringComparison]::OrdinalIgnoreCase)
}

function Write-StepBanner {
    param([string]$Message)
    $width = [Math]::Max(48, $Message.Length)
    $pad = $width - $Message.Length
    $left = [int][Math]::Floor($pad / 2)
    $right = $pad - $left
    $bar = '*' * $width
    Write-Host ''
    Write-Host $bar
    Write-Host (('*' * $left) + $Message + ('*' * $right))
    Write-Host $bar
    Write-Host ''
}

function Invoke-Checked {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$DisplayName = $Exe
    )
    Write-Host "##[section]$DisplayName"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Exe $($Arguments -join ' ')"
    }
}

function Get-SalesforceCliVersion {
    $text = (& sf --version 2>&1 | Out-String).Trim()
    Write-Host $text
    if ($text -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return 'unknown'
}

function Get-SfPluginVersion {
    param([string[]]$Names)
    $text = (& sf plugins 2>&1 | Out-String)
    Write-Host $text
    foreach ($name in $Names) {
        $pattern = '(?im)^\s*' + [regex]::Escape($name) + '\s+v?(\d+\.\d+\.\d+)'
        if ($text -match $pattern) { return $Matches[1] }
    }
    return 'unknown'
}

function Install-SfCli {
    param([string]$Version)
    $spec = '@salesforce/cli@latest'
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $trimmed = $Version.Trim()
        if ($trimmed -notin @('latest', 'stable')) {
            $spec = "@salesforce/cli@$trimmed"
        }
    }
    Write-Host "##[section]Install Salesforce CLI $spec"
    Invoke-Checked -Exe 'npm' -Arguments @('install', '--global', $spec) -DisplayName "npm install -g $spec"
    $cliVersion = Get-SalesforceCliVersion
    Write-StepBanner "Salesforce CLI $cliVersion installed."
}

function Test-IsWindowsOs {
    if ($PSVersionTable.PSEdition -eq 'Core' -and $null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) {
        return $IsWindows
    }
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Get-SfPluginAllowListName {
    param([string]$PluginSpec)
    $spec = $PluginSpec.Trim()
    if ($spec.StartsWith('@')) {
        $secondAt = $spec.IndexOf('@', 1)
        if ($secondAt -gt 0) { return $spec.Substring(0, $secondAt) }
        return $spec
    }
    $at = $spec.IndexOf('@')
    if ($at -gt 0) { return $spec.Substring(0, $at) }
    return $spec
}

function Add-UnsignedPluginAllowList {
    param([string]$PluginName)
    # Piping "yes" into sf plugins install crashes the CLI on Node 24 (write EINVAL).
    # An allowlisted name installs with no trust prompt.
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add((Join-Path $HOME '.config/sf'))
    if ((Test-IsWindowsOs) -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $localDir = Join-Path $env:LOCALAPPDATA 'sf'
        if ($dirs -notcontains $localDir) { $dirs.Add($localDir) }
    }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $file = Join-Path $dir 'unsignedPluginAllowList.json'
        $names = @()
        if (Test-Path -LiteralPath $file) {
            try {
                $existing = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                if ($null -ne $existing) { $names = @($existing) }
            }
            catch {
                $names = @()
            }
        }
        if ($names -notcontains $PluginName) { $names += $PluginName }
        $escaped = $names | ForEach-Object { '"' + (($_ -replace '\\', '\\') -replace '"', '\"') + '"' }
        Set-Content -LiteralPath $file -Value ('[' + ($escaped -join ',') + ']') -Encoding ascii
        Write-Host "Allowlisted unsigned plugin '$PluginName' in $file"
    }
}

function Invoke-SfPluginInstallNonInteractive {
    param([string]$PluginSpec)
    $allowName = Get-SfPluginAllowListName -PluginSpec $PluginSpec
    Add-UnsignedPluginAllowList -PluginName $allowName
    Invoke-Checked -Exe 'sf' -Arguments @('plugins', 'install', $PluginSpec) -DisplayName "sf plugins install $PluginSpec"
}

function Install-SfdxGitDeltaPlugin {
    Write-Host "##[section]Install sfdx-git-delta plugin"
    Invoke-SfPluginInstallNonInteractive -PluginSpec 'sfdx-git-delta@stable'
    $pluginVersion = Get-SfPluginVersion -Names @('sfdx-git-delta')
    Write-StepBanner "sfdx-git-delta $pluginVersion installed."
}

function Install-CodeAnalyzerPlugin {
    Write-Host "##[section]Install code-analyzer plugin"
    Invoke-SfPluginInstallNonInteractive -PluginSpec 'code-analyzer'
    $pluginVersion = Get-SfPluginVersion -Names @('code-analyzer', '@salesforce/plugin-code-analyzer')
    Write-StepBanner "Code Analyzer $pluginVersion installed."
}

function Resolve-JwtInstanceUrl {
    param(
        [string]$InstanceUrl,
        [string]$OrgType
    )
    if (-not [string]::IsNullOrWhiteSpace($InstanceUrl)) {
        return $InstanceUrl.Trim()
    }
    $t = if ([string]::IsNullOrWhiteSpace($OrgType)) { 'sandbox' } else { $OrgType.Trim().ToLowerInvariant() }
    switch ($t) {
        'production' { return 'https://login.salesforce.com' }
        'sandbox' { return 'https://test.salesforce.com' }
        default { return 'https://test.salesforce.com' }
    }
}

function Connect-SfOrgJwt {
    param(
        [string]$Username,
        [string]$ClientId,
        [string]$InstanceUrl,
        [string]$OrgType,
        [string]$Alias,
        [string]$JwtKeyPath
    )
    if ([string]::IsNullOrWhiteSpace($ClientId)) { throw 'client_id is required for JWT authentication.' }
    if ([string]::IsNullOrWhiteSpace($Username)) { throw 'username is required for JWT authentication.' }
    $resolvedUrl = Resolve-JwtInstanceUrl -InstanceUrl $InstanceUrl -OrgType $OrgType
    if ([string]::IsNullOrWhiteSpace($JwtKeyPath) -or -not (Test-Path -LiteralPath $JwtKeyPath)) {
        throw "JWT key file not found: $JwtKeyPath"
    }
    Write-Host "##[section]Authorize org via JWT ($Alias) instance=$resolvedUrl orgType=$OrgType"
    Invoke-Checked -Exe 'sf' -Arguments @(
        'org', 'login', 'jwt',
        '--client-id', $ClientId,
        '--jwt-key-file', $JwtKeyPath,
        '--username', $Username,
        '--instance-url', $resolvedUrl,
        '--alias', $Alias
    )
    & sf alias list
}

function Connect-SfOrgAuthUrl {
    param(
        [string]$Alias,
        [string]$AuthUrlFile,
        [string]$AuthUrlValue,
        [string]$SourcesRoot
    )
    $fileToUse = $null
    if (-not [string]::IsNullOrWhiteSpace($AuthUrlFile)) {
        $p = if ([IO.Path]::IsPathRooted($AuthUrlFile)) { $AuthUrlFile } else { Join-Path $SourcesRoot $AuthUrlFile }
        if (-not (Test-Path -LiteralPath $p)) {
            throw "SFDX Auth URL file not found: $p"
        }
        $fileToUse = $p
    }
    elseif (-not [string]::IsNullOrWhiteSpace($AuthUrlValue)) {
        $tmpDir = Join-Path $SourcesRoot '.sf-auth'
        if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null }
        $fileToUse = Join-Path $tmpDir 'sfdx-auth-url.txt'
        Set-Content -LiteralPath $fileToUse -Value $AuthUrlValue.Trim() -NoNewline -Encoding utf8
        Write-Host "Wrote SFDX Auth URL from secret input to temporary file for login."
    }
    else {
        throw 'Auth URL mode requires either SFDX Auth URL file path or SFDX Auth URL (secret variable).'
    }

    Write-Host "##[section]Authorize org via SFDX Auth URL ($Alias)"
    Invoke-Checked -Exe 'sf' -Arguments @(
        'org', 'login', 'sfdx-url',
        '--sfdx-url-file', $fileToUse,
        '--alias', $Alias
    )
    & sf alias list
}

function Connect-SfOrg {
    param(
        [string]$AuthMethod,
        [string]$Alias,
        [string]$Username,
        [string]$ClientId,
        [string]$InstanceUrl,
        [string]$OrgType,
        [string]$JwtKeyPath,
        [string]$AuthUrlFile,
        [string]$AuthUrlValue,
        [string]$SourcesRoot
    )
    $method = if ([string]::IsNullOrWhiteSpace($AuthMethod)) { 'jwt' } else { $AuthMethod.Trim().ToLowerInvariant() }
    switch ($method) {
        'jwt' {
            Connect-SfOrgJwt -Username $Username -ClientId $ClientId -InstanceUrl $InstanceUrl -OrgType $OrgType -Alias $Alias -JwtKeyPath $JwtKeyPath
        }
        'authurl' {
            Connect-SfOrgAuthUrl -Alias $Alias -AuthUrlFile $AuthUrlFile -AuthUrlValue $AuthUrlValue -SourcesRoot $SourcesRoot
        }
        default {
            throw "Unsupported authMethod '$AuthMethod'. Use jwt or authUrl."
        }
    }
    Write-StepBanner 'Org authenticated.'
}

function Resolve-IgnoreFileArg {
    param([string]$SourcesRoot, [string]$IgnoreFileInput)
    $candidate = $IgnoreFileInput
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $default1 = Join-Path $SourcesRoot 'ignorefile'
        if (Test-Path -LiteralPath $default1) { return $default1 }
        $default2 = Join-Path $SourcesRoot '.sgdignore'
        if (Test-Path -LiteralPath $default2) { return $default2 }
        return $null
    }
    $p = if ([IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path $SourcesRoot $candidate }
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Invoke-SgdDelta {
    param(
        [string]$SourcesRoot,
        [string]$FromRef,
        [string]$ToRef,
        [string]$IgnoreFile
    )
    Write-Host "##[section]sfdx-git-delta ($FromRef .. $ToRef)"
    Set-Location $SourcesRoot
    $args = @(
        'sgd', 'source', 'delta',
        '--to', $ToRef,
        '--from', $FromRef,
        '--output', '.',
        '--ignore-destructive', 'ignoredestructive',
        '--include-destructive', 'includedestructive'
    )
    if ($IgnoreFile) {
        $args += @('--ignore-file', $IgnoreFile)
    }
    Invoke-Checked -Exe 'sf' -Arguments $args -DisplayName 'sf sgd source delta'
    if (-not (Test-Path (Join-Path $SourcesRoot 'package/package.xml'))) {
        throw "package/package.xml not found after delta. Check git history and paths."
    }
    Write-StepBanner 'Delta package generated.'
}

function Copy-DeltaArtifacts {
    param([string]$SourcesRoot)
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $artifactFolder = Join-Path $SourcesRoot 'artifacts'
    if (-not (Test-Path $artifactFolder)) {
        New-Item -ItemType Directory -Force -Path $artifactFolder | Out-Null
    }
    $pkg = Join-Path $SourcesRoot 'package/package.xml'
    $dest = Join-Path $artifactFolder "package_$ts.xml"
    Copy-Item -LiteralPath $pkg -Destination $dest -Force
    $destr = Join-Path $SourcesRoot 'destructiveChanges/destructiveChanges.xml'
    if (Test-Path -LiteralPath $destr) {
        Copy-Item -LiteralPath $destr -Destination (Join-Path $artifactFolder "destructiveChanges_$ts.xml") -Force
    }
    Write-Host "Delta artifacts copied under $artifactFolder"
}

function Get-SpecifiedTestNames {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    return @(
        $Raw -split '[,;\s]+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Add-DeployTestLevelArgs {
    param(
        [System.Collections.Generic.List[string]]$ArgsList,
        [string]$TestLevel,
        [string]$SpecifiedTests
    )
    $ArgsList.AddRange([string[]]@('--test-level', $TestLevel))
    if ($TestLevel -eq 'RunSpecifiedTests') {
        $names = Get-SpecifiedTestNames -Raw $SpecifiedTests
        if ($names.Count -eq 0) {
            throw 'RunSpecifiedTests was selected but no test class names were provided.'
        }
        foreach ($n in $names) {
            $ArgsList.AddRange([string[]]@('--tests', $n))
        }
    }
}

function ConvertFrom-SfJsonText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }
    try {
        return ($Text.Substring($start, $end - $start + 1) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-ComponentFailures {
    param($Report)
    $failures = $null
    if ($Report -and $Report.result -and $Report.result.details -and $Report.result.details.componentFailures) {
        $failures = @($Report.result.details.componentFailures)
    }
    if (-not $failures -or $failures.Count -eq 0) { return }
    foreach ($f in $failures) {
        $typeName = [string]$f.componentType
        $fullName = [string]$f.fullName
        $problem = [string]$f.problem
        if ([string]::IsNullOrWhiteSpace($problem)) { $problem = [string]$f.error }
        Write-Host "##[error]$typeName $fullName : $problem"
    }
}

function Get-SfDeployStatus {
    param(
        [string]$Alias,
        [string]$WaitMinutes,
        [string]$CommandOutput
    )
    if ([string]::IsNullOrWhiteSpace($WaitMinutes)) { $WaitMinutes = '120' }
    Write-Host "##[section]sf project deploy report"
    $reportText = & sf project deploy report --target-org $Alias --use-most-recent --wait $WaitMinutes --json 2>&1 | Out-String
    Write-Host $reportText
    $report = ConvertFrom-SfJsonText -Text $reportText
    Write-ComponentFailures -Report $report
    $status = $null
    if ($report -and $report.result -and $report.result.status) {
        $status = [string]$report.result.status
    }
    if ([string]::IsNullOrWhiteSpace($status) -and $CommandOutput -match 'Status:\s*(Succeeded|Failed|Canceled|Cancelled)') {
        $status = $Matches[1]
    }
    if ($status -eq 'Cancelled') { $status = 'Canceled' }
    if ([string]::IsNullOrWhiteSpace($status)) {
        if ($CommandOutput -match 'metadata\.transfer:Finalizing') { $status = 'Unknown' }
        else { $status = 'Failed' }
    }
    return [pscustomobject]@{ Status = $status; Report = $report }
}

function Test-ApexClassCoverage {
    param(
        $Report,
        [int]$MinimumPercent,
        [string]$TestLevel
    )
    if ($TestLevel -eq 'NoTestRun') { return $true }
    $rows = $null
    if ($Report -and $Report.result -and $Report.result.details -and $Report.result.details.runTestResult -and $Report.result.details.runTestResult.codeCoverage) {
        $rows = @($Report.result.details.runTestResult.codeCoverage)
    }
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Host "##[warning]The deploy report did not include per-class Apex coverage, so the $MinimumPercent% coverage check was skipped."
        return $true
    }
    $passed = $true
    foreach ($row in $rows) {
        $locations = 0
        $uncovered = 0
        [void][int]::TryParse([string]$row.numLocations, [ref]$locations)
        [void][int]::TryParse([string]$row.numLocationsNotCovered, [ref]$uncovered)
        if ($locations -le 0) { continue }
        $covered = $locations - $uncovered
        $pct = [int][math]::Floor(($covered / $locations) * 100)
        $name = [string]$row.name
        Write-Host "Apex coverage for ${name}: ${pct}% (${covered}/${locations} lines)."
        if ($pct -lt $MinimumPercent) {
            $passed = $false
            Write-Host "##[error]$name coverage is $pct%, which is below the required $MinimumPercent%."
        }
    }
    return $passed
}

function Invoke-SfOrgDeploy {
    param(
        [string]$ActionName,
        [string]$Alias,
        [string]$PackageXml,
        [string]$DestructiveXml,
        [string]$TestLevel,
        [string]$SpecifiedTests,
        [string]$WaitMinutes,
        [bool]$IgnoreWarnings,
        [bool]$IgnoreConflicts,
        [bool]$DryRun,
        [int]$MinimumCoverage
    )
    if ([string]::IsNullOrWhiteSpace($WaitMinutes)) { $WaitMinutes = '120' }
    $args = [System.Collections.Generic.List[string]]::new()
    $args.AddRange([string[]]@('project', 'deploy', 'start', '--manifest', $PackageXml))
    if ($DestructiveXml -and (Test-Path -LiteralPath $DestructiveXml)) {
        $args.AddRange([string[]]@('--post-destructive-changes', $DestructiveXml))
    }
    if ($IgnoreConflicts -and -not $DryRun) { $args.Add('--ignore-conflicts') }
    $args.AddRange([string[]]@('--target-org', $Alias))
    Add-DeployTestLevelArgs -ArgsList $args -TestLevel $TestLevel -SpecifiedTests $SpecifiedTests
    if ($IgnoreWarnings) { $args.Add('--ignore-warnings') }
    if ($DryRun) { $args.Add('--dry-run') }
    $args.AddRange([string[]]@('--wait', $WaitMinutes, '--verbose'))

    Write-Host "##[section]sf $($args -join ' ')"
    $lines = & sf @($args.ToArray()) 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($lines)) { Write-Host $line }
    $text = @($lines) | Out-String
    if ($code -ne 0 -and $text -match 'metadata\.transfer:Finalizing') {
        Write-Host "##[warning]Salesforce CLI exited $code while formatting the Finalizing status. The org result is read from the deploy report."
    }

    $outcome = Get-SfDeployStatus -Alias $Alias -WaitMinutes $WaitMinutes -CommandOutput $text
    if ($outcome.Status -eq 'Unknown') {
        $outcome = Get-SfDeployStatus -Alias $Alias -WaitMinutes $WaitMinutes -CommandOutput ''
    }
    $coverageOk = $true
    if ($outcome.Status -eq 'Succeeded') {
        $coverageOk = Test-ApexClassCoverage -Report $outcome.Report -MinimumPercent $MinimumCoverage -TestLevel $TestLevel
    }
    $sentence = switch ($outcome.Status) {
        'Succeeded' {
            if ($coverageOk) { "$ActionName succeeded." }
            else { "$ActionName failed. Coverage below $MinimumCoverage%." }
        }
        'Canceled' { "$ActionName canceled." }
        default { "$ActionName failed." }
    }
    Write-StepBanner $sentence
    if ($outcome.Status -ne 'Succeeded' -or -not $coverageOk) {
        throw $sentence
    }
}

function Resolve-PathFromRoot {
    param([string]$SourcesRoot, [string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $SourcesRoot $PathValue)
}

function New-CodeAnalyzerConfigWithPmd {
    param(
        [string]$SourcesRoot,
        [string]$PmdRulesetPath
    )
    $resolved = Resolve-PathFromRoot -SourcesRoot $SourcesRoot -PathValue $PmdRulesetPath
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "PMD ruleset file not found: $resolved"
    }
    $cfgDir = Join-Path $SourcesRoot 'reports'
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
    $cfgPath = Join-Path $cfgDir 'code-analyzer-pmd-config.yml'
    # Salesforce Code Analyzer config: custom PMD ruleset for this run
    $yaml = @"
engines:
  pmd:
    disable_engine: false
    custom_rulesets:
      - "$($resolved.Replace('\', '/'))"
"@
    Set-Content -LiteralPath $cfgPath -Value $yaml -Encoding utf8
    Write-Host "Generated Code Analyzer config with custom PMD ruleset: $cfgPath"
    return $cfgPath
}

function Invoke-CodeAnalyzerOnDelta {
    param(
        [string]$SourcesRoot,
        [string]$FromRef,
        [string]$ToRef,
        [string]$RuleSelector,
        [string]$SeverityThreshold,
        [string]$ReportCsv,
        [bool]$UseCustomPmd,
        [string]$PmdRulesetPath
    )
    $changed = Join-Path $SourcesRoot 'changed-sources'
    if (Test-Path $changed) { Remove-Item -Recurse -Force $changed }
    New-Item -ItemType Directory -Force -Path $changed | Out-Null
    $reports = Join-Path $SourcesRoot 'reports'
    if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Force -Path $reports | Out-Null }

    Set-Location $SourcesRoot
    Invoke-Checked -Exe 'sf' -Arguments @(
        'sgd', 'source', 'delta',
        '--to', $ToRef,
        '--from', $FromRef,
        '--output-dir', 'changed-sources/',
        '--generate-delta'
    ) -DisplayName 'sf sgd source delta (generate-delta for analyzer)'

    $workspace = Join-Path $changed 'force-app'
    if (-not (Test-Path $workspace)) {
        Write-Host "##[warning]No changed-sources/force-app; skipping Code Analyzer (no delta metadata paths)."
        return
    }

    $args = [System.Collections.Generic.List[string]]::new()
    $args.AddRange([string[]]@('code-analyzer', 'run', '--workspace', $workspace, '--severity-threshold', $SeverityThreshold, '--output-file', $ReportCsv))

    if ($UseCustomPmd) {
        if ([string]::IsNullOrWhiteSpace($PmdRulesetPath)) {
            throw 'Use custom PMD ruleset is enabled but PMD ruleset XML path is empty.'
        }
        $cfg = New-CodeAnalyzerConfigWithPmd -SourcesRoot $SourcesRoot -PmdRulesetPath $PmdRulesetPath
        $args.AddRange([string[]]@('--config-file', $cfg, '--rule-selector', 'pmd'))
        Write-Host "##[section]sf code-analyzer run (custom PMD ruleset)"
    }
    else {
        if ([string]::IsNullOrWhiteSpace($RuleSelector)) { $RuleSelector = 'all' }
        $args.AddRange([string[]]@('--rule-selector', $RuleSelector))
        Write-Host "##[section]sf code-analyzer run (default rule selector: $RuleSelector)"
    }

    Invoke-Checked -Exe 'sf' -Arguments @($args.ToArray()) -DisplayName 'sf code-analyzer run (delta workspace)'
    Write-StepBanner 'Code Analyzer finished.'
}

function ConvertTo-SeverityNumber {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $t = $Raw.Trim()
    $n = 0
    if ([int]::TryParse($t, [ref]$n)) { return $n }
    switch -Regex ($t.ToLowerInvariant()) {
        '^(critical|high|sev1)$' { return 1 }
        '^(error|medium|sev2)$' { return 2 }
        '^(warning|low|sev3)$' { return 3 }
        '^(info|sev4)$' { return 4 }
        default { return $null }
    }
}

function Test-CodeAnalyzerSeverityGate {
    param(
        [string]$CsvPath,
        [int]$MaxAllowedSeverity
    )
    if (-not (Test-Path -LiteralPath $CsvPath)) {
        Write-Host "##[warning]Code Analyzer CSV not found at $CsvPath; severity gate skipped."
        return
    }
    $rows = Import-Csv -LiteralPath $CsvPath
    $failed = @()
    foreach ($r in $rows) {
        $sevProp = $null
        if ($r.PSObject.Properties['Severity']) { $sevProp = $r.Severity }
        elseif ($r.PSObject.Properties['severity']) { $sevProp = $r.severity }
        $num = ConvertTo-SeverityNumber -Raw ([string]$sevProp)
        if ($null -ne $num -and $num -gt $MaxAllowedSeverity) {
            $failed += $r
        }
    }
    if ($failed.Count -gt 0) {
        $msg = "Code Analyzer: $($failed.Count) finding(s) exceed max allowed severity ($MaxAllowedSeverity)."
        Write-Host "##vso[task.logissue type=error]$msg"
        Write-StepBanner 'Code Analyzer failed.'
        throw $msg
    }
}

function Publish-PipelineArtifactFromFolder {
    param(
        [string]$FolderPath,
        [string]$ArtifactName,
        [string]$ContainerFolder
    )
    if (-not (Test-Path -LiteralPath $FolderPath)) {
        Write-Host "##[warning]Artifact folder missing: $FolderPath"
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($ContainerFolder)) { $ContainerFolder = 'Artifact' }
    $rootFull = (Resolve-Path -LiteralPath $FolderPath).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse)
    if ($files.Count -eq 0) {
        Write-Host "##[warning]No files to publish in $FolderPath"
        return $false
    }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        $relativeDir = [IO.Path]::GetDirectoryName($relative)
        $folder = $ContainerFolder
        if (-not [string]::IsNullOrWhiteSpace($relativeDir)) {
            $folder = $ContainerFolder + '/' + ($relativeDir.Replace('\', '/'))
        }
        Write-Host "Publishing $($file.Name) to $ArtifactName/$folder"
        Write-Host "##vso[artifact.upload containerfolder=$folder;artifactname=$ArtifactName;artifacttype=container;]$($file.FullName)"
    }
    return $true
}

$root = $env:BUILD_SOURCESDIRECTORY
if ([string]::IsNullOrWhiteSpace($root)) { $root = Get-Location }
Set-Location $root

$operationMode = Get-TaskInput -Name 'operationMode'
if ([string]::IsNullOrWhiteSpace($operationMode)) { $operationMode = 'auto' }

$alias = Get-TaskInput -Name 'alias'
$authMethod = Get-TaskInput -Name 'authMethod'
if ([string]::IsNullOrWhiteSpace($authMethod)) { $authMethod = 'jwt' }
$orgType = Get-TaskInput -Name 'orgType'
if ([string]::IsNullOrWhiteSpace($orgType)) { $orgType = 'sandbox' }
$clientId = Get-TaskInput -Name 'client_id'
$username = Get-TaskInput -Name 'username'
$instanceUrl = Get-TaskInput -Name 'instance_url'
$jwtKeyFile = Get-TaskInput -Name 'jwt_key_file'
$jwtSecureFile = Get-TaskInput -Name 'jwtKeySecureFile'
$jwtTokenPath = Get-TaskInput -Name 'jwt_token_path'
$jwtPath = if (-not [string]::IsNullOrWhiteSpace($jwtTokenPath)) { $jwtTokenPath }
    elseif (-not [string]::IsNullOrWhiteSpace($jwtSecureFile)) { $jwtSecureFile }
    else { $jwtKeyFile }
if (-not [string]::IsNullOrWhiteSpace($jwtPath)) {
    $jwtPath = $jwtPath.Trim().Trim('"')
    $jwtPathWithoutParen = $jwtPath.TrimEnd([char]')')
    if (-not (Test-Path -LiteralPath $jwtPath) -and $jwtPath.EndsWith(')') -and (Test-Path -LiteralPath $jwtPathWithoutParen)) {
        Write-Host "##[warning]JWT path had a trailing parenthesis. Using $jwtPathWithoutParen."
        $jwtPath = $jwtPathWithoutParen
    }
}
$sfdxAuthUrlFile = Get-TaskInput -Name 'sfdx_auth_url_file'
$sfdxAuthUrlSecureFile = Get-TaskInput -Name 'sfdxAuthUrlSecureFile'
if (-not [string]::IsNullOrWhiteSpace($sfdxAuthUrlSecureFile)) { $sfdxAuthUrlFile = $sfdxAuthUrlSecureFile.Trim().Trim('"') }
$sfdxAuthUrl = Get-TaskInput -Name 'sfdx_auth_url'

$sfVer = Get-TaskInput -Name 'sfCliVersion'

$skipCli = Test-InputBool (Get-TaskInput -Name 'skipInstallSfCli')
$fromRef = Get-TaskInput -Name 'deltaFromRef'
$toRef = Get-TaskInput -Name 'deltaToRef'
if ([string]::IsNullOrWhiteSpace($fromRef)) { $fromRef = 'HEAD~1' }
if ([string]::IsNullOrWhiteSpace($toRef)) { $toRef = 'HEAD' }

$ignoreInput = Get-TaskInput -Name 'ignoreFile'
$targetBranch = Get-TaskInput -Name 'targetBranch'
if ([string]::IsNullOrWhiteSpace($targetBranch)) { $targetBranch = 'develop' }

$validateTestLevel = Get-TaskInput -Name 'validateTestLevel'
if ([string]::IsNullOrWhiteSpace($validateTestLevel)) { $validateTestLevel = 'NoTestRun' }
$validateSpecifiedTests = Get-TaskInput -Name 'validateSpecifiedTests'
$deployTestLevel = Get-TaskInput -Name 'deployTestLevel'
if ([string]::IsNullOrWhiteSpace($deployTestLevel)) { $deployTestLevel = 'NoTestRun' }
$deploySpecifiedTests = Get-TaskInput -Name 'deploySpecifiedTests'
$codeCoverageRaw = Get-TaskInput -Name 'codeCoveragePercent'
$minimumCoverage = 75
if (-not [string]::IsNullOrWhiteSpace($codeCoverageRaw)) {
    $parsedCoverage = 0
    $coverageText = $codeCoverageRaw.Trim().TrimEnd('%')
    if (-not [int]::TryParse($coverageText, [ref]$parsedCoverage) -or $parsedCoverage -lt 0 -or $parsedCoverage -gt 100) {
        throw "Code coverage percent must be a whole number from 0 to 100. Received '$codeCoverageRaw'."
    }
    $minimumCoverage = $parsedCoverage
}

$deployWaitTime = Get-TaskInput -Name 'deployWaitTime'
if ([string]::IsNullOrWhiteSpace($deployWaitTime)) { $deployWaitTime = '120' }
$ignoreWarnings = Test-InputBool (Get-TaskInput -Name 'ignoreWarnings')
$ignoreConflicts = Test-InputBool (Get-TaskInput -Name 'ignoreConflicts')
# Default ignoreConflicts to true when input missing (ADO may omit falsey defaults in some hosts)
if ([string]::IsNullOrWhiteSpace((Get-TaskInput -Name 'ignoreConflicts'))) { $ignoreConflicts = $true }

$runAnalyzer = Test-InputBool (Get-TaskInput -Name 'runCodeAnalyzer')
$useCustomPmd = Test-InputBool (Get-TaskInput -Name 'useCustomPmdRuleset')
$pmdRulesetPath = Get-TaskInput -Name 'pmdRulesetPath'
$ruleSel = Get-TaskInput -Name 'codeAnalyzerRuleSelector'
if ([string]::IsNullOrWhiteSpace($ruleSel)) { $ruleSel = 'all' }
$analyzerThresh = Get-TaskInput -Name 'codeAnalyzerSeverityThreshold'
if ([string]::IsNullOrWhiteSpace($analyzerThresh)) { $analyzerThresh = '2' }
$enforceGate = Test-InputBool (Get-TaskInput -Name 'enforceSeverityGate')
if ([string]::IsNullOrWhiteSpace((Get-TaskInput -Name 'enforceSeverityGate'))) { $enforceGate = $true }
$maxSevStr = Get-TaskInput -Name 'maxAllowedSeverity'
$maxAllowed = 2
if (-not [string]::IsNullOrWhiteSpace($maxSevStr)) {
    $parsedMax = 0
    if ([int]::TryParse($maxSevStr, [ref]$parsedMax)) { $maxAllowed = $parsedMax }
}

$pubDelta = Test-InputBool (Get-TaskInput -Name 'publishDeltaArtifact')
if ([string]::IsNullOrWhiteSpace((Get-TaskInput -Name 'publishDeltaArtifact'))) { $pubDelta = $true }
$deltaArtName = Get-TaskInput -Name 'deltaArtifactName'
if ([string]::IsNullOrWhiteSpace($deltaArtName)) { $deltaArtName = 'Delta-Package' }
$pubCa = Test-InputBool (Get-TaskInput -Name 'publishCodeAnalyzerArtifact')
$caArtName = Get-TaskInput -Name 'codeAnalyzerArtifactName'
if ([string]::IsNullOrWhiteSpace($caArtName)) { $caArtName = 'sf-code-analyzer' }

$buildReason = $env:BUILD_REASON
$prId = $env:SYSTEM_PULLREQUEST_PULLREQUESTID
$prTarget = $env:SYSTEM_PULLREQUEST_TARGETBRANCH
$prTargetName = Get-NormalizedBranchName $prTarget
$buildBranchName = Get-NormalizedBranchName $env:BUILD_SOURCEBRANCH

$resolved = $operationMode
if ($operationMode -eq 'auto') {
    if ($buildReason -eq 'PullRequest' -or $prId) {
        if (-not (Test-BranchNameEquals -A $prTargetName -B $targetBranch)) {
            Write-Host "##[command]Auto: skipping validation - PR target branch is '$prTargetName'; this task is configured for PRs that target '$targetBranch' only."
            exit 0
        }
        $resolved = 'validate'
    }
    elseif (Test-BranchNameEquals -A $buildBranchName -B $targetBranch) {
        $resolved = 'deploy'
    }
    else {
        Write-Host "##[command]Auto: skipping - pipeline branch is '$buildBranchName'; deploy runs only when the build runs on '$targetBranch' after merge (not a PR build)."
        exit 0
    }
}
elseif ($resolved -ne 'validate' -and $resolved -ne 'deploy') {
    throw "Unsupported operationMode '$operationMode'. Use auto, validate, or deploy."
}

Write-Host "##[section]Salesforce org validate/deploy (delta) | mode=$resolved | sources=$root"

function Test-GitRef {
    param([string]$Ref)
    git rev-parse $Ref 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

$shallow = (git rev-parse --is-shallow-repository 2>$null | Out-String).Trim()
if ($shallow -eq 'true' -or -not (Test-GitRef $fromRef) -or -not (Test-GitRef $toRef)) {
    Write-Host "##[section]Fetching full git history so $fromRef exists"
    git fetch --unshallow 2>&1 | ForEach-Object { Write-Host $_ }
    if (-not (Test-GitRef $fromRef)) {
        git fetch origin $targetBranch --depth=50 2>&1 | ForEach-Object { Write-Host $_ }
    }
}
if (-not (Test-GitRef $fromRef)) {
    throw "Git could not resolve '$fromRef' after fetching history."
}
if (-not (Test-GitRef $toRef)) {
    throw "Git could not resolve '$toRef'."
}
Write-StepBanner 'Git history ready.'

if (-not $skipCli) {
    Install-SfCli -Version $sfVer
}
else {
    if (-not (Get-Command sf -ErrorAction SilentlyContinue)) { throw 'sf CLI not found; uncheck skip install or pre-install CLI.' }
    $cliVersion = Get-SalesforceCliVersion
    Write-StepBanner "Salesforce CLI $cliVersion already installed."
}

Install-SfdxGitDeltaPlugin
if ($runAnalyzer -and ($resolved -eq 'validate')) {
    Install-CodeAnalyzerPlugin
}

Connect-SfOrg -AuthMethod $authMethod -Alias $alias -Username $username -ClientId $clientId -InstanceUrl $instanceUrl -OrgType $orgType -JwtKeyPath $jwtPath -AuthUrlFile $sfdxAuthUrlFile -AuthUrlValue $sfdxAuthUrl -SourcesRoot $root

$ignoreResolved = Resolve-IgnoreFileArg -SourcesRoot $root -IgnoreFileInput $ignoreInput

$stepError = $null
try {
    Invoke-SgdDelta -SourcesRoot $root -FromRef $fromRef -ToRef $toRef -IgnoreFile $ignoreResolved
    Copy-DeltaArtifacts -SourcesRoot $root

    $pkgXml = Join-Path $root 'package/package.xml'
    $destXml = Join-Path $root 'destructiveChanges/destructiveChanges.xml'

    if ($runAnalyzer -and ($resolved -eq 'validate')) {
        $reportCsv = Join-Path $root 'reports/code-analyzer-report.csv'
        Invoke-CodeAnalyzerOnDelta -SourcesRoot $root -FromRef $fromRef -ToRef $toRef -RuleSelector $ruleSel -SeverityThreshold $analyzerThresh -ReportCsv $reportCsv -UseCustomPmd $useCustomPmd -PmdRulesetPath $pmdRulesetPath
        if ($enforceGate -and (Test-Path -LiteralPath $reportCsv)) {
            Test-CodeAnalyzerSeverityGate -CsvPath $reportCsv -MaxAllowedSeverity $maxAllowed
        }
    }

    if ($resolved -eq 'validate') {
        Write-Host "Validate test level: $validateTestLevel | wait=$deployWaitTime | ignoreWarnings=$ignoreWarnings"
        Invoke-SfOrgDeploy -ActionName 'Validation' -Alias $alias -PackageXml $pkgXml -DestructiveXml $destXml -TestLevel $validateTestLevel -SpecifiedTests $validateSpecifiedTests -WaitMinutes $deployWaitTime -IgnoreWarnings $ignoreWarnings -IgnoreConflicts $false -DryRun $true -MinimumCoverage $minimumCoverage
    }
    elseif ($resolved -eq 'deploy') {
        Write-Host "Deploy test level: $deployTestLevel | wait=$deployWaitTime | ignoreWarnings=$ignoreWarnings | ignoreConflicts=$ignoreConflicts"
        Invoke-SfOrgDeploy -ActionName 'Deployment' -Alias $alias -PackageXml $pkgXml -DestructiveXml $destXml -TestLevel $deployTestLevel -SpecifiedTests $deploySpecifiedTests -WaitMinutes $deployWaitTime -IgnoreWarnings $ignoreWarnings -IgnoreConflicts $ignoreConflicts -DryRun $false -MinimumCoverage $minimumCoverage
    }
}
catch {
    $stepError = $_
}
finally {
    if ($pubCa) {
        try {
            if (Publish-PipelineArtifactFromFolder -FolderPath (Join-Path $root 'reports') -ArtifactName $caArtName -ContainerFolder 'Code-Analyzer') {
                Write-StepBanner 'Code Analyzer artifact published.'
            }
        }
        catch {
            Write-Host "##[warning]Could not publish Code Analyzer artifact: $_"
        }
    }
    if ($pubDelta) {
        try {
            if (Publish-PipelineArtifactFromFolder -FolderPath (Join-Path $root 'artifacts') -ArtifactName $deltaArtName -ContainerFolder 'Delta-Package') {
                Write-StepBanner 'Delta artifact published.'
            }
        }
        catch {
            Write-Host "##[warning]Could not publish delta artifact: $_"
        }
    }
}
if ($null -ne $stepError) {
    Write-Host "##vso[task.logissue type=error]$stepError"
    throw $stepError
}
