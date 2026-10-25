param([int]$Port = 38082, [string]$OutDir = '', [string]$Data = '')
# One-click offline demo: start the backend, walk the whole business loop, stop it.
#
# What this is for: a course/competition demonstration that needs no cloud host, no
# device, no npm install and no network. It is deliberately narrower than verify.ps1 —
# verify.ps1 is the regression; this is the thing you can run in front of someone.
#
# What it does NOT prove: cloud deployment, device notifications/cards, real model calls,
# or external access. Those stay blocked and are reported as such.
#
# Usage:
#   pwsh -NoProfile -File src/backend/demo-offline.ps1
#   pwsh -NoProfile -File src/backend/demo-offline.ps1 -Port 38085 -OutDir audit/backend/my_demo
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/pscompat.ps1')
Assert-PowerShell7
Set-Utf8Console
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$stamp = Get-Date -Format 'yyyyMMddTHHmmssfff'
if (!$OutDir) { $OutDir = Join-Path $workspace 'audit/backend/local_closure_20261025' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
if (!$Data) { $Data = Join-Path $workspace 'src/data/synthetic.runtime.json' }

$latestPath = Join-Path $workspace 'temp/backend/latest-build.json'
if (!(Test-Path -LiteralPath $latestPath)) { throw 'No build record. Run: pwsh -File src/backend/build-cjc.ps1' }
$buildRoot = (Read-JsonFile $latestPath).buildRoot
$exe = Join-Path $buildRoot 'backend/target/release/bin/main.exe'
if (!(Test-Path -LiteralPath $exe)) { throw ('main.exe not found under ' + $buildRoot + '. Rebuild first.') }

$runDir = Join-Path $workspace ('temp/backend/offline_demo_' + $stamp)
Write-Host ('[1/3] starting backend on port ' + $Port + ' ...')
& (Join-Path $PSScriptRoot 'start.ps1') -Port $Port -RunDirectory $runDir -BuildRoot $buildRoot -Data $Data | Out-Null
$server = Read-JsonFile (Join-Path $workspace 'temp/backend/latest-server.json')
if (!$server.url) { throw 'start.ps1 did not report a server url' }

$walkthrough = Join-Path $OutDir 'walkthrough.json'
$exit = 0
try {
    Write-Host ('[2/3] walking the loop against ' + $server.url + ' ...')
    $env:ICT_BASE_URL = $server.url
    & node (Join-Path $PSScriptRoot 'tests/local.walkthrough.mjs') --base $server.url --out $walkthrough
    $exit = $LASTEXITCODE
} finally {
    Write-Host '[3/3] stopping backend ...'
    & (Join-Path $PSScriptRoot 'stop.ps1') | Out-Null
}

$walk = $null
if (Test-Path -LiteralPath $walkthrough) { $walk = Read-JsonFile $walkthrough }
$summary = @{
    schema        = 'ict-local-closure-v1'
    completedAt   = (Get-Date -Format o)
    mode          = 'offline_demo'
    serverUrl     = $server.url
    runDirectory  = $runDir
    buildRoot     = $buildRoot
    mainExeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLower()
    walkthrough   = $(if ($walk) { 'audit/backend/' + (Split-Path $OutDir -Leaf) + '/walkthrough.json' } else { $null })
    steps         = $(if ($walk) { $walk.counts } else { $null })
    exitCode      = $exit
    status        = $(if ($exit -eq 0) { 'passed' } else { 'failed' })
    notCovered    = @(
        'cloud deployment and external access (no cloud host)',
        'device notifications / cards / receipt on device (no device target)',
        'real model call (no provider credentials; gateway stays G0)',
        'blind evaluation or AI gain (synthetic data, self-authored labels)'
    )
}
Write-JsonFile (Join-Path $OutDir 'demo-summary.json') $summary 12
Write-Host ('done: ' + $summary.status + ' -> ' + (Join-Path $OutDir 'demo-summary.json'))
exit $exit
