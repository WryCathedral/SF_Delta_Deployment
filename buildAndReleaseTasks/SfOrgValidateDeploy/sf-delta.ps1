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

function Repair-OptionalPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $candidate = $PathValue.Trim().Trim('"')
    $withoutParen = $candidate.TrimEnd([char]')')
    if (-not (Test-Path -LiteralPath $candidate) -and $candidate.EndsWith(')') -and (Test-Path -LiteralPath $withoutParen)) {
        Write-Host "##[warning]Path had a trailing parenthesis. Using $withoutParen."
        return $withoutParen
    }
    return $candidate
}

function Get-SecureFileAccessToken {
    $token = [Environment]::GetEnvironmentVariable('ENDPOINT_AUTH_PARAMETER_SYSTEMVSSCONNECTION_ACCESSTOKEN')
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable('SYSTEM_ACCESSTOKEN')
    }
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    return $token.Trim()
}

function Get-SafeServiceMessage {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt 8000) { return $null }
    $text = [Text.Encoding]::UTF8.GetString($Bytes).Trim()
    if (-not $text.StartsWith('{')) { return $null }
    try { $obj = $text | ConvertFrom-Json } catch { return $null }
    $message = [string]$obj.message
    if ([string]::IsNullOrWhiteSpace($message)) { return $null }
    if ($message -match 'BEGIN |PRIVATE KEY|ssh-rsa') { return $null }
    if ($message.Length -gt 240) { $message = $message.Substring(0, 240) }
    return $message
}

function Test-DownloadedFileBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $false }
    $sampleLength = [Math]::Min(120, $Bytes.Length)
    $sample = [Text.Encoding]::UTF8.GetString($Bytes, 0, $sampleLength).TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
    if ($sample.StartsWith('{') -or $sample.StartsWith('<') -or $sample.StartsWith('$id')) { return $false }
    return $true
}

function Save-AgentSecureFile {
    param(
        [Parameter(Mandatory = $true)][string]$FileId,
        [string]$Label
    )
    $id = $FileId.Trim()
    $ticket = [Environment]::GetEnvironmentVariable("SECUREFILE_TICKET_$id")
    $secureName = [Environment]::GetEnvironmentVariable("SECUREFILE_NAME_$id")
    if ([string]::IsNullOrWhiteSpace($ticket)) { return $null }

    $safeName = if ([string]::IsNullOrWhiteSpace($secureName)) { $id } else { [IO.Path]::GetFileName($secureName) }
    $collection = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI
    if ([string]::IsNullOrWhiteSpace($collection)) { $collection = $env:SYSTEM_COLLECTIONURI }
    $project = $env:SYSTEM_TEAMPROJECT
    if ([string]::IsNullOrWhiteSpace($collection) -or [string]::IsNullOrWhiteSpace($project)) {
        throw "Cannot download $Label. The agent did not provide the collection URI or project name."
    }

    $tempRoot = $env:AGENT_TEMPDIRECTORY
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = [IO.Path]::GetTempPath() }
    $destDir = Join-Path $tempRoot 'sf-delta-secure'
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    $dest = Join-Path $destDir $safeName
    $accessToken = Get-SecureFileAccessToken
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Could not download $Label '$safeName'. The agent did not provide the pipeline access token."
    }
    $basicToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $accessToken))
    $ticketEscaped = [Uri]::EscapeDataString($ticket)
    $projectEscaped = [Uri]::EscapeDataString($project)
    $collectionRoot = $collection.TrimEnd('/')
    Write-Host "Downloading $Label '$safeName'."

    $downloaded = $false
    $lastStatus = 0
    $lastMessage = $null
    $client = $null
    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromMinutes(2)
        $attempts = @(
            @{ Authorization = ('Basic ' + $basicToken); Download = 'false' },
            @{ Authorization = ('Bearer ' + $accessToken); Download = 'false' },
            @{ Authorization = ('Bearer ' + $accessToken); Download = 'true' }
        )
        for ($attempt = 1; $attempt -le $attempts.Count; $attempt++) {
            $style = $attempts[$attempt - 1]
            $request = $null
            $response = $null
            try {
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
                $uri = '{0}/{1}/_apis/distributedtask/securefiles/{2}?ticket={3}&download={4}&api-version=5.0-preview.1' -f $collectionRoot, $projectEscaped, $id, $ticketEscaped, $style.Download
                $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
                [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/octet-stream')
                [void]$request.Headers.TryAddWithoutValidation('Authorization', $style.Authorization)
                [void]$request.Headers.TryAddWithoutValidation('X-TFS-FedAuthRedirect', 'Suppress')
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
                $lastStatus = [int]$response.StatusCode
                $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                $lastMessage = Get-SafeServiceMessage -Bytes $bytes
                if ($lastStatus -ge 200 -and $lastStatus -lt 300 -and (Test-DownloadedFileBytes -Bytes $bytes)) {
                    [System.IO.File]::WriteAllBytes($dest, $bytes)
                    $downloaded = $true
                    break
                }
                $detail = "HTTP $lastStatus"
                if (-not [string]::IsNullOrWhiteSpace($lastMessage)) { $detail = "$detail. $lastMessage" }
                Write-Host "##[warning]Download attempt $attempt for '$safeName' did not return the file ($detail)."
            }
            catch {
                Write-Host "##[warning]Download attempt $attempt for '$safeName' failed."
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
            }
            finally {
                if ($response) { $response.Dispose() }
                if ($request) { $request.Dispose() }
            }
            if ($attempt -lt $attempts.Count) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    finally {
        if ($client) { $client.Dispose() }
    }

    if (-not $downloaded) {
        $detail = "HTTP $lastStatus"
        if (-not [string]::IsNullOrWhiteSpace($lastMessage)) { $detail = "$detail. $lastMessage" }
        throw "Could not download $Label '$safeName' ($detail)."
    }
    if (-not (Test-IsWindowsOs)) {
        & chmod 600 -- $dest
        if ($LASTEXITCODE -ne 0) {
            Write-Host "##[warning]Could not restrict permissions on '$safeName'."
        }
    }
    return $dest
}

function Resolve-SecureOrPathInput {
    param(
        [string]$SecureFileValue,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($SecureFileValue)) { return $null }
    $secureValue = $SecureFileValue.Trim().Trim('"')
    if (Test-Path -LiteralPath $secureValue) {
        return (Resolve-Path -LiteralPath $secureValue).Path
    }
    $downloaded = Save-AgentSecureFile -FileId $secureValue -Label $Label
    if (-not [string]::IsNullOrWhiteSpace($downloaded)) { return $downloaded }
    throw "$Label secure file was selected, but the agent did not provide a download ticket. Re-select the file on the task and authorize the pipeline to use it."
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

function Get-VersionFromPluginText {
    param(
        [string]$Text,
        [string[]]$Names
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($name in $Names) {
        $pattern = [regex]::Escape($name) + '[^\r\n]{0,160}?v?(\d+\.\d+\.\d+)'
        if ($Text -match $pattern) { return $Matches[1] }
    }
    if ($Text -match 'installed v?(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-SfPluginVersion {
    param(
        [string[]]$Names,
        [string]$InstallOutput
    )
    $fromInstall = Get-VersionFromPluginText -Text $InstallOutput -Names $Names
    if (-not [string]::IsNullOrWhiteSpace($fromInstall)) { return $fromInstall }

    $jsonLog = Join-Path ([IO.Path]::GetTempPath()) ('sf-plugins-' + [guid]::NewGuid().ToString() + '.log')
    & sf plugins --json > $jsonLog 2>&1
    $jsonText = ''
    if (Test-Path -LiteralPath $jsonLog) {
        $jsonText = Get-Content -LiteralPath $jsonLog -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $jsonLog -Force -ErrorAction SilentlyContinue
    }
    $fromJson = Get-VersionFromPluginText -Text $jsonText -Names $Names
    if (-not [string]::IsNullOrWhiteSpace($fromJson)) { return $fromJson }
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
    Write-Host "##[section]sf plugins install $PluginSpec"
    $log = Join-Path ([IO.Path]::GetTempPath()) ('sf-plugin-install-' + [guid]::NewGuid().ToString() + '.log')
    & sf plugins install $PluginSpec > $log 2>&1
    $exitCode = $LASTEXITCODE
    $output = ''
    if (Test-Path -LiteralPath $log) {
        $output = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($output)) { Write-Host $output }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0) {
        throw "Command failed (${exitCode}): sf plugins install $PluginSpec"
    }
    return $output
}

function Install-SfdxGitDeltaPlugin {
    Write-Host "##[section]Install sfdx-git-delta plugin"
    $installOutput = Invoke-SfPluginInstallNonInteractive -PluginSpec 'sfdx-git-delta@stable'
    $pluginVersion = Get-SfPluginVersion -Names @('sfdx-git-delta') -InstallOutput $installOutput
    Write-StepBanner "sfdx-git-delta $pluginVersion installed."
}

function Install-CodeAnalyzerPlugin {
    Write-Host "##[section]Install code-analyzer plugin"
    $installOutput = Invoke-SfPluginInstallNonInteractive -PluginSpec 'code-analyzer'
    $pluginVersion = Get-SfPluginVersion -Names @('code-analyzer', '@salesforce/plugin-code-analyzer') -InstallOutput $installOutput
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

function Convert-JwtPrivateKeyFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = $null
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    else {
        $offset = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $offset = 3 }
        $text = [Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    $text = $text.Trim().Trim([char]0xFEFF)
    if ($text.StartsWith('ssh-rsa ') -or $text.StartsWith('ssh-ed25519 ') -or $text.StartsWith('ecdsa-sha2-')) {
        throw 'The JWT file is an OpenSSH public key. Upload the private key, not the .pub file.'
    }
    if ($text.StartsWith('{') -or $text.StartsWith('<')) {
        throw 'The JWT file is not a private key. The download returned a service message instead of the key file. Authorize the pipeline for that secure file and run again.'
    }

    $blocks = [regex]::Matches($text, '-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $chosen = $null
    foreach ($block in $blocks) {
        if ($block.Value -match 'PRIVATE KEY') { $chosen = $block.Value.Trim(); break }
    }
    if ([string]::IsNullOrWhiteSpace($chosen) -and $blocks.Count -gt 0) { $chosen = $blocks[0].Value.Trim() }
    if ([string]::IsNullOrWhiteSpace($chosen)) {
        throw "The JWT file is $($bytes.Length) bytes and does not contain a PEM private key. Upload an unencrypted RSA key that starts with BEGIN RSA PRIVATE KEY or BEGIN PRIVATE KEY."
    }
    $chosen = ($chosen -replace "`r`n", "`n" -replace "`r", "`n").Trim() + "`n"
    $header = 'unrecognized'
    if ($chosen -match '-----BEGIN ([A-Z0-9 ]+)-----') { $header = $Matches[1] }

    $tempRoot = $env:AGENT_TEMPDIRECTORY
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = [System.IO.Path]::GetTempPath() }
    $destDir = Join-Path $tempRoot 'sf-delta-secure'
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    $dest = Join-Path $destDir 'jwt-private-key.pem'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($dest, $chosen, $utf8)
    if (-not (Test-IsWindowsOs)) { & chmod 600 -- $dest | Out-Null }

    if ($header -eq 'OPENSSH PRIVATE KEY') {
        Write-Host 'Converting OpenSSH private key to PEM.'
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & ssh-keygen -p -m PEM -f $dest -P '' -N '' > $null
        $convertCode = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        if ($convertCode -ne 0) {
            throw 'The secure file is an OpenSSH private key and could not be converted. Upload an unencrypted RSA key in PEM format.'
        }
        $converted = [System.IO.File]::ReadAllText($dest)
        if ($converted -match '-----BEGIN ([A-Z0-9 ]+)-----') { $header = $Matches[1] }
    }
    if ($header -match 'ENCRYPTED') {
        throw 'The private key is encrypted. Salesforce JWT needs an unencrypted PEM private key.'
    }
    if ($header -match 'CERTIFICATE|PUBLIC KEY') {
        throw "The secure file is a $header, not a private key. Upload the RSA private key for the connected app."
    }
    if ($header -notmatch 'PRIVATE KEY') {
        throw "The secure file format '$header' is not an RSA private key. Upload a PEM file that starts with BEGIN RSA PRIVATE KEY or BEGIN PRIVATE KEY."
    }

    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if ($openssl) {
        $opensslLog = Join-Path $tempRoot ('openssl-jwt-' + [guid]::NewGuid().ToString() + '.log')
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & openssl pkey -in $dest -noout 2> $opensslLog
        $opensslOk = $LASTEXITCODE -eq 0
        $ErrorActionPreference = $previousPreference
        if (Test-Path -LiteralPath $opensslLog) { Remove-Item -LiteralPath $opensslLog -Force -ErrorAction SilentlyContinue }
        if (-not $opensslOk) {
            throw 'OpenSSL could not read the JWT private key. Upload an unencrypted RSA PEM private key.'
        }
    }
    Write-Host "JWT private key format: $header."
    return $dest
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
        if ($JwtKeyPath -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            throw "JWT key file not found: $JwtKeyPath. That value is a secure file id. Select it in JWT private key secure file and authorize the pipeline to use it."
        }
        throw "JWT key file not found: $JwtKeyPath"
    }
    $JwtKeyPath = Convert-JwtPrivateKeyFile -Path $JwtKeyPath
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
$jwtKeyFile = Repair-OptionalPath (Get-TaskInput -Name 'jwt_key_file')
$jwtSecureFile = Get-TaskInput -Name 'jwtKeySecureFile'
$jwtTokenPath = Repair-OptionalPath (Get-TaskInput -Name 'jwt_token_path')
$jwtPath = $null
if (-not [string]::IsNullOrWhiteSpace($jwtTokenPath) -and (Test-Path -LiteralPath $jwtTokenPath)) {
    $jwtPath = $jwtTokenPath
}
elseif (-not [string]::IsNullOrWhiteSpace($jwtSecureFile)) {
    if (-not [string]::IsNullOrWhiteSpace($jwtTokenPath)) {
        Write-Host '##[warning]JWT path override was not found. Downloading the JWT private key secure file.'
    }
    $jwtPath = Resolve-SecureOrPathInput -SecureFileValue $jwtSecureFile -Label 'JWT private key'
}
elseif (-not [string]::IsNullOrWhiteSpace($jwtTokenPath)) {
    $jwtPath = $jwtTokenPath
}
else {
    $jwtPath = $jwtKeyFile
}
$sfdxAuthUrlPath = Repair-OptionalPath (Get-TaskInput -Name 'sfdx_auth_url_file')
$sfdxAuthUrlSecureFile = Get-TaskInput -Name 'sfdxAuthUrlSecureFile'
$sfdxAuthUrlFile = $null
if (-not [string]::IsNullOrWhiteSpace($sfdxAuthUrlPath) -and (Test-Path -LiteralPath $sfdxAuthUrlPath)) {
    $sfdxAuthUrlFile = $sfdxAuthUrlPath
}
elseif (-not [string]::IsNullOrWhiteSpace($sfdxAuthUrlSecureFile)) {
    $sfdxAuthUrlFile = Resolve-SecureOrPathInput -SecureFileValue $sfdxAuthUrlSecureFile -Label 'SFDX Auth URL'
}
else {
    $sfdxAuthUrlFile = $sfdxAuthUrlPath
}
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
