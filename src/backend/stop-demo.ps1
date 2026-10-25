param([string]$DemoRecord = '')
$ErrorActionPreference = 'Stop'
if (!$DemoRecord) { $DemoRecord = Join-Path $PSScriptRoot '../../temp/integration/latest-demo.json' }
$demo = Get-Content -LiteralPath $DemoRecord -Raw | ConvertFrom-Json
$web = Get-Process -Id $demo.web.processId -ErrorAction SilentlyContinue
if ($web) {
    $command = (Get-CimInstance Win32_Process -Filter "ProcessId=$($web.Id)").CommandLine
    if ($web.Path -ne $demo.web.exe -or $command -notmatch 'node_modules/vite/bin/vite.js' -or $command -notmatch "--port $($demo.web.port)\b") { throw 'Web process identity mismatch' }
    Stop-Process -Id $web.Id
}
& (Join-Path $PSScriptRoot 'stop.ps1') -ServerRecord (Join-Path $demo.backend.runDirectory 'server.json')
$demo | Add-Member -Force NoteProperty running $false
$demo | Add-Member -Force NoteProperty stoppedAt (Get-Date -Format o)
$demo | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $DemoRecord -Encoding utf8
Write-Output 'Owned demo backend and Web stopped'
