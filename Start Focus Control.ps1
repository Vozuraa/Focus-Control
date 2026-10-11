$applicationPath = Join-Path $PSScriptRoot 'Focus Control.ps1'
$arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $applicationPath + '"'
Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden
