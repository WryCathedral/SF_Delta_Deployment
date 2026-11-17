$dir = Split-Path -Parent $PSScriptRoot
$iconPath = Join-Path $dir "images\extension-icon.png"
$b = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
[IO.File]::WriteAllBytes($iconPath, $b)
