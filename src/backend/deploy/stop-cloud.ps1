param()
# Stop the cloud bundle started by start-cloud.ps1.
#
# Only processes recorded in state/server.json are stopped, and only after checking that
# the recorded PID still points at the expected executable. Anything else is left alone.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$receiptPath = Join-Path $root 'state/server.json'
if (!(Test-Path -LiteralPath $receiptPath)) { Write-Output 'no state/server.json; nothing to stop'; return }
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json

function Stop-Owned([int]$processId, [string]$expectedName) {
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (!$process) { Write-Output ("pid $processId already gone"); return }
    if ($process.ProcessName -ne $expectedName) { Write-Output ("pid $processId is $($process.ProcessName), not $expectedName; skipped"); return }
    Stop-Process -Id $processId -Force
    Write-Output ("stopped $expectedName pid $processId")
}

if ($receipt.proxyPid) { Stop-Owned -processId $receipt.proxyPid -expectedName 'node' }
if ($receipt.backendPid) { Stop-Owned -processId $receipt.backendPid -expectedName 'main' }
Write-Output 'done'
