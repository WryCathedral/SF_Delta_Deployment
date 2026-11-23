# Unit tests for the delta manifest display and Flow version expansion in sf-delta.ps1.
# They load the real functions from the task script and replace `sf` with a mock.
#
# Run: powershell -NoProfile -File tests/Test-FlowDestructive.ps1   (or pwsh)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\buildAndReleaseTasks\SfOrgValidateDeploy\sf-delta.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath).Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Host "PARSE ERROR: $($_.Message)" }
    exit 1
}

$wanted = @(
    'ConvertFrom-SfJsonText', 'Get-JsonProperty', 'Test-ManifestHasTypes', 'Write-ManifestContents',
    'Show-DeltaManifests', 'Get-UnversionedFlowMembers', 'Get-OrgFlowVersions',
    'Expand-FlowDestructiveVersions', 'Copy-ExpandedDestructiveArtifact'
)
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($name in $wanted) {
    $definition = $functions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $definition) { Write-Host "MISSING FUNCTION: $name"; exit 1 }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# ---- mock sf -------------------------------------------------------------
$script:sfCalls = New-Object System.Collections.Generic.List[string]
$script:flowVersions = @{}
$script:queryExit = 0
$script:queryNoise = ''

function sf {
    $script:sfCalls.Add(($args -join ' '))
    $global:LASTEXITCODE = $script:queryExit
    if ($script:queryExit -ne 0) { return 'ERROR: query failed' }
    $query = [string]$args[([array]::IndexOf($args, '--query') + 1)]
    $names = @([regex]::Matches($query, "'((?:[^'\\]|\\.)*)'") | ForEach-Object { $_.Groups[1].Value })
    $records = @()
    foreach ($n in $names) {
        if ($script:flowVersions.ContainsKey($n)) {
            foreach ($v in $script:flowVersions[$n]) {
                $records += @{ attributes = @{ type = 'Flow' }; VersionNumber = $v; Definition = @{ attributes = @{ type = 'FlowDefinition' }; DeveloperName = $n } }
            }
        }
    }
    $json = @{ status = 0; result = @{ size = $records.Count; totalSize = $records.Count; records = $records } } | ConvertTo-Json -Depth 8
    return ($script:queryNoise + $json)
}

# ---- helpers -------------------------------------------------------------
$script:passed = 0
$script:failed = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:passed++; Write-Host "  PASS  $Name" }
    else { $script:failed++; Write-Host "  FAIL  $Name $Detail" }
}
function Capture-Host { param([scriptblock]$Block) return (& $Block *>&1 | Out-String) }

$work = Join-Path ([IO.Path]::GetTempPath()) ('flow-destructive-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
function New-TestFile {
    param([string]$Name, [string]$Content)
    $p = Join-Path $work $Name
    [IO.File]::WriteAllText($p, $Content, (New-Object System.Text.UTF8Encoding $false))
    return $p
}
function Reset-Mock { $script:sfCalls.Clear(); $script:flowVersions = @{}; $script:queryExit = 0; $script:queryNoise = '' }

$header = '<?xml version="1.0" encoding="UTF-8"?>' + "`n" + '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' + "`n"
function New-Destructive {
    param([string[]]$Blocks, [string]$ApiVersion = '64.0')
    return $header + (($Blocks | ForEach-Object { $_ }) -join "`n") + "`n    <version>$ApiVersion</version>`n</Package>`n"
}
function New-TypeBlock {
    param([string]$TypeName, [string[]]$Members)
    $lines = ($Members | ForEach-Object { "        <members>$_</members>" }) -join "`n"
    return "    <types>`n$lines`n        <name>$TypeName</name>`n    </types>"
}

try {
    Write-Host 'Flow version expansion'

    Write-Host ' 1. active flow with several versions expands to every ApiName-N'
    Reset-Mock
    $script:flowVersions['Account_Flow'] = @(3, 1, 2)
    $p = New-TestFile 'd1.xml' (New-Destructive @((New-TypeBlock 'Flow' @('Account_Flow')), (New-TypeBlock 'ApexClass' @('OldClass'))))
    $r = Expand-FlowDestructiveVersions -Path $p -Alias 'qa'
    $x = [IO.File]::ReadAllText($p)
    Assert-That 'Changed is true' ($r.Changed -eq $true)
    Assert-That 'HasTypes is true' ($r.HasTypes -eq $true)
    Assert-That 'versions 1,2,3 present in ascending order' ($x -match '(?s)<members>Account_Flow-1</members>\s*<members>Account_Flow-2</members>\s*<members>Account_Flow-3</members>')
    Assert-That 'unversioned name removed' ($x -notmatch '<members>Account_Flow</members>')
    Assert-That 'ApexClass block untouched' ($x -match '(?s)<members>OldClass</members>\s*<name>ApexClass</name>')
    Assert-That 'api version preserved' ($x -match '<version>64.0</version>')
    Assert-That 'result is well-formed XML' (([xml]$x).Package.types.Count -eq 2)
    Assert-That 'one Tooling API query' ($script:sfCalls.Count -eq 1 -and $script:sfCalls[0] -match 'data query --use-tooling-api --target-org qa --query SELECT VersionNumber, Definition.DeveloperName FROM Flow WHERE Definition.DeveloperName IN \(''Account_Flow''\) --json')

    Write-Host ' 2. already versioned members are left alone and no query is made'
    Reset-Mock
    $orig = New-Destructive @((New-TypeBlock 'Flow' @('Account_Flow-4', 'Other_Flow-1')))
    $p = New-TestFile 'd2.xml' $orig
    $r = Expand-FlowDestructiveVersions -Path $p -Alias 'qa'
    Assert-That 'Changed is false' ($r.Changed -eq $false)
    Assert-That 'file unchanged' ([IO.File]::ReadAllText($p) -eq $orig)
    Assert-That 'sf was not called' ($script:sfCalls.Count -eq 0)

    Write-Host ' 3. mix of versioned and unversioned members, de-duplicated'
    Reset-Mock
    $script:flowVersions['A_Flow'] = @(1, 2)
    $p = New-TestFile 'd3.xml' (New-Destructive @((New-TypeBlock 'Flow' @('A_Flow', 'A_Flow-2', 'B_Flow-7'))))
    [void](Expand-FlowDestructiveVersions -Path $p -Alias 'qa')
    $members = @([regex]::Matches([IO.File]::ReadAllText($p), '<members>([^<]+)</members>') | ForEach-Object { $_.Groups[1].Value })
    Assert-That 'members are A_Flow-1, A_Flow-2, B_Flow-7' (($members -join ',') -eq 'A_Flow-1,A_Flow-2,B_Flow-7') "got $($members -join ',')"

    Write-Host ' 4. flow that no longer exists in the org is omitted, other types stay'
    Reset-Mock
    $p = New-TestFile 'd4.xml' (New-Destructive @((New-TypeBlock 'Flow' @('Gone_Flow')), (New-TypeBlock 'ApexClass' @('OldClass'))))
    $r = Expand-FlowDestructiveVersions -Path $p -Alias 'qa'
    $x = [IO.File]::ReadAllText($p)
    Assert-That 'Changed is true' ($r.Changed -eq $true)
    Assert-That 'Flow type removed' ($x -notmatch '<name>Flow</name>')
    Assert-That 'ApexClass kept' ($x -match '<members>OldClass</members>')
    Assert-That 'HasTypes is true' ($r.HasTypes -eq $true)

    Write-Host ' 5. only a missing flow leaves a valid empty Package with the original API version'
    Reset-Mock
    $p = New-TestFile 'd5.xml' (New-Destructive -Blocks @((New-TypeBlock 'Flow' @('Gone_Flow'))) -ApiVersion '66.0')
    $r = Expand-FlowDestructiveVersions -Path $p -Alias 'qa'
    $x = [IO.File]::ReadAllText($p)
    Assert-That 'no <types> left' ($x -notmatch '<types>')
    Assert-That 'HasTypes is false' ($r.HasTypes -eq $false)
    Assert-That 'API version 66.0 kept' ($x -match '<version>66.0</version>')
    Assert-That 'valid XML' (([xml]$x).Package.version -eq '66.0')
    Assert-That 'file has no BOM' ([IO.File]::ReadAllBytes($p)[0] -eq 60)

    Write-Host ' 6. file without Flow types is not touched'
    Reset-Mock
    $orig = New-Destructive @((New-TypeBlock 'ApexClass' @('OldClass')))
    $p = New-TestFile 'd6.xml' $orig
    $r = Expand-FlowDestructiveVersions -Path $p -Alias 'qa'
    Assert-That 'Changed is false' ($r.Changed -eq $false)
    Assert-That 'file unchanged' ([IO.File]::ReadAllText($p) -eq $orig)
    Assert-That 'sf was not called' ($script:sfCalls.Count -eq 0)

    Write-Host ' 7. empty destructive manifest (no types) is not touched'
    Reset-Mock
    $orig = $header + "    <version>64.0</version>`n</Package>`n"
    $p = New-TestFile 'd7.xml' $orig
    $r = Expand-FlowDestructiveVersions -Path $p -Alias 'qa'
    Assert-That 'Changed false, HasTypes false' ($r.Changed -eq $false -and $r.HasTypes -eq $false)
    Assert-That 'file unchanged' ([IO.File]::ReadAllText($p) -eq $orig)

    Write-Host ' 8. missing file is a no-op'
    Reset-Mock
    $r = Expand-FlowDestructiveVersions -Path (Join-Path $work 'does-not-exist.xml') -Alias 'qa'
    Assert-That 'Changed false' ($r.Changed -eq $false)

    Write-Host ' 9. failed query stops the task and leaves the file as it was'
    Reset-Mock
    $script:queryExit = 1
    $orig = New-Destructive @((New-TypeBlock 'Flow' @('Account_Flow')))
    $p = New-TestFile 'd9.xml' $orig
    $threw = $false
    try { [void](Capture-Host { Expand-FlowDestructiveVersions -Path $p -Alias 'qa' }) } catch { $threw = $true }
    Assert-That 'throws' $threw
    Assert-That 'file unchanged' ([IO.File]::ReadAllText($p) -eq $orig)

    Write-Host '10. CLI warnings before the JSON do not break parsing'
    Reset-Mock
    $script:queryNoise = "Warning: @salesforce/cli update available from 2.1.0 to 2.2.0.`n"
    $script:flowVersions['Account_Flow'] = @(1)
    $p = New-TestFile 'd10.xml' (New-Destructive @((New-TypeBlock 'Flow' @('Account_Flow'))))
    [void](Expand-FlowDestructiveVersions -Path $p -Alias 'qa')
    Assert-That 'expanded despite the warning line' ([IO.File]::ReadAllText($p) -match '<members>Account_Flow-1</members>')

    Write-Host '11. CRLF files keep CRLF line endings'
    Reset-Mock
    $script:flowVersions['Account_Flow'] = @(1, 2)
    $crlf = (New-Destructive @((New-TypeBlock 'Flow' @('Account_Flow')))) -replace "`n", "`r`n"
    $p = New-TestFile 'd11.xml' $crlf
    [void](Expand-FlowDestructiveVersions -Path $p -Alias 'qa')
    $x = [IO.File]::ReadAllText($p)
    Assert-That 'no bare LF' ($x -notmatch "(?<!`r)`n")
    Assert-That 'versions present' ($x -match 'Account_Flow-2')

    Write-Host '12. more than 50 flows are queried in batches'
    Reset-Mock
    $names = 1..120 | ForEach-Object { "Flow_$_" }
    foreach ($n in $names) { $script:flowVersions[$n] = @(1) }
    $p = New-TestFile 'd12.xml' (New-Destructive @((New-TypeBlock 'Flow' $names)))
    [void](Expand-FlowDestructiveVersions -Path $p -Alias 'qa')
    $members = @([regex]::Matches([IO.File]::ReadAllText($p), '<members>([^<]+)</members>'))
    Assert-That '3 queries for 120 flows' ($script:sfCalls.Count -eq 3) "got $($script:sfCalls.Count)"
    Assert-That 'all 120 expanded' ($members.Count -eq 120) "got $($members.Count)"
    Assert-That 'every member is versioned' (@($members | Where-Object { $_.Groups[1].Value -notmatch '-1$' }).Count -eq 0)

    Write-Host '13. flow with a record flattened as Definition.DeveloperName is understood'
    # Covered by the property fallback in Get-OrgFlowVersions; exercise the helper directly.
    $flat = [pscustomobject]@{ VersionNumber = 5; 'Definition.DeveloperName' = 'Flat_Flow' }
    Assert-That 'Get-JsonProperty reads dotted name' ((Get-JsonProperty -Object $flat -Name 'Definition.DeveloperName') -eq 'Flat_Flow')
    Assert-That 'Get-JsonProperty returns null for missing' ($null -eq (Get-JsonProperty -Object $flat -Name 'Nope'))

    Write-Host 'Delta manifest display'

    Write-Host '14. package.xml and destructiveChanges.xml contents are printed'
    $root = Join-Path $work 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'package'), (Join-Path $root 'destructiveChanges') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'package/package.xml'), "<Package><types><members>MyClass</members><name>ApexClass</name></types></Package>`n")
    [IO.File]::WriteAllText((Join-Path $root 'destructiveChanges/destructiveChanges.xml'), "<Package><types><members>MyFlow</members><name>Flow</name></types></Package>`n")
    $out = Capture-Host { Show-DeltaManifests -SourcesRoot $root }
    Assert-That 'shows package heading and body' ($out -match 'package/package.xml' -and $out -match '<members>MyClass</members>')
    Assert-That 'shows destructive heading and body' ($out -match 'destructiveChanges.xml' -and $out -match '<members>MyFlow</members>')

    Write-Host '15. a missing destructiveChanges.xml is reported, not an error'
    Remove-Item (Join-Path $root 'destructiveChanges/destructiveChanges.xml')
    $out = Capture-Host { Show-DeltaManifests -SourcesRoot $root }
    Assert-That 'says there are no deletions' ($out -match 'no deletions')
    Assert-That 'package.xml still shown' ($out -match 'MyClass')

    Write-Host '16. lines that start with ## cannot become pipeline commands'
    [IO.File]::WriteAllText((Join-Path $root 'package/package.xml'), "##vso[task.complete result=Failed;]x`n<Package/>`n")
    $out = Capture-Host { Show-DeltaManifests -SourcesRoot $root }
    Assert-That '##vso is neutralised' ($out -notmatch '(?m)^##vso\[')

    Write-Host '17. Test-ManifestHasTypes'
    Assert-That 'false for missing file' ((Test-ManifestHasTypes -Path (Join-Path $work 'nope.xml')) -eq $false)
    Assert-That 'true for real <types> block' ((Test-ManifestHasTypes -Path (New-TestFile 't2.xml' '<Package><types><name>X</name></types></Package>')) -eq $true)
    Assert-That 'false for empty Package' ((Test-ManifestHasTypes -Path (New-TestFile 't3.xml' '<Package><version>64.0</version></Package>')) -eq $false)

    Write-Host '18. expanded manifest is copied into the delta artifacts folder'
    $p = New-TestFile 'd18.xml' '<Package/>'
    Copy-ExpandedDestructiveArtifact -SourcesRoot $root -Path $p
    Assert-That 'artifact file written' (@(Get-ChildItem (Join-Path $root 'artifacts') -Filter 'destructiveChanges_flow-versions_*.xml').Count -eq 1)
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $($script:passed)  Failed: $($script:failed)"
if ($script:failed -gt 0) { exit 1 }
exit 0
