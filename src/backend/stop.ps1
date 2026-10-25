param([string]$ServerRecord = '')
$ErrorActionPreference = 'Stop'
if (!$ServerRecord) { $ServerRecord = Join-Path $PSScriptRoot '../../temp/backend/latest-server.json' }
$server = Get-Content -LiteralPath $ServerRecord -Raw | ConvertFrom-Json
$process = Get-Process -Id $server.processId -ErrorAction SilentlyContinue
if ($process) {
    if ([IO.Path]::GetFullPath($process.Path) -ne [IO.Path]::GetFullPath($server.exe)) { throw 'Process identity mismatch; refusing to stop' }
    Stop-Process -Id $process.Id
    $process.WaitForExit()
}
$stoppedAt = Get-Date -Format o
$server | Add-Member -Force NoteProperty running $false
$server | Add-Member -Force NoteProperty stoppedAt $stoppedAt
$server | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $ServerRecord -Encoding utf8
$latest = Join-Path $PSScriptRoot '../../temp/backend/latest-server.json'
if (Test-Path -LiteralPath $latest) {
    $pointer = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
    if ($pointer.processId -eq $server.processId -and $pointer.runDirectory -eq $server.runDirectory) { $server | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $latest -Encoding utf8 }
}
@{processId=$server.processId;stoppedAt=$stoppedAt;stopped=!(Get-Process -Id $server.processId -ErrorAction SilentlyContinue);serverRecord=$ServerRecord} | ConvertTo-Json
