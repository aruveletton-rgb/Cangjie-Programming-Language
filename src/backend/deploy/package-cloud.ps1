param(
    [string]$BuildRoot = '',
    [string]$OutDir = '',
    [switch]$Force
)
# Assemble a self-contained Windows cloud bundle.
#
# The bundle is what gets uploaded to a Windows Server instance: the compiled exe, the
# stdx runtime, the synthetic dataset, and the deploy scripts. Nothing in it references
# the workspace, so the cloud host does not need the source tree.
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if (!$BuildRoot) {
    $latest = Join-Path $workspace 'temp/backend/latest-build.json'
    if (!(Test-Path -LiteralPath $latest)) { throw 'No build record. Build first.' }
    $BuildRoot = (Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json).buildRoot
}
$exe = Join-Path $BuildRoot 'backend/target/release/bin/main.exe'
if (!(Test-Path -LiteralPath $exe)) { $exe = Join-Path $BuildRoot 'main.exe' }
if (!(Test-Path -LiteralPath $exe)) { throw ('main.exe not found under ' + $BuildRoot) }
$stdx = Join-Path $BuildRoot 'stdx'
if (!(Test-Path -LiteralPath $stdx)) { throw ('stdx not found under ' + $BuildRoot) }

if (!$OutDir) { $OutDir = Join-Path $workspace 'artifacts/backend/cloud-bundle' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if ((Test-Path -LiteralPath $OutDir) -and !$Force) { throw ('OutDir exists; pass -Force to replace: ' + $OutDir) }
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }

New-Item -ItemType Directory -Path $OutDir, (Join-Path $OutDir 'deploy'), (Join-Path $OutDir 'data') -Force | Out-Null
Copy-Item -LiteralPath $exe -Destination (Join-Path $OutDir 'main.exe')
Copy-Item -LiteralPath $stdx -Destination (Join-Path $OutDir 'stdx') -Recurse
Copy-Item -LiteralPath (Join-Path $workspace 'src/data/synthetic.runtime.json') -Destination (Join-Path $OutDir 'data/synthetic.runtime.json')
foreach ($file in @('tls-proxy.mjs', 'preflight-provider.mjs', 'preflight-deploy.mjs', 'provider.env.example', 'gen-cert.sh', 'start-cloud.ps1', 'stop-cloud.ps1')) {
    $source = Join-Path $PSScriptRoot $file
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $OutDir ('deploy/' + $file)) }
}

$files = Get-ChildItem -LiteralPath $OutDir -Recurse -File | Where-Object { $_.Name -ne 'bundle-manifest.json' }
$manifest = @{
    schema      = 'ict-cloud-bundle-v1'
    builtAt     = (Get-Date -Format o)
    buildRoot   = $BuildRoot
    target      = 'x86_64-w64-mingw32 (Windows)'
    hostImage   = 'Windows Server'
    entry       = @{
        backend = 'main.exe'
        proxy   = 'deploy/tls-proxy.mjs'
        start   = 'deploy/start-cloud.ps1'
        stop    = 'deploy/stop-cloud.ps1'
    }
    files       = @($files | ForEach-Object {
        @{
            path   = $_.FullName.Substring($OutDir.Length + 1).Replace('\', '/')
            bytes  = $_.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLower()
        }
    })
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'bundle-manifest.json') -Encoding utf8
Write-Output ('bundle=' + $OutDir)
Write-Output ('files=' + $manifest.files.Count)
Write-Output ('main.exe sha256=' + ($manifest.files | Where-Object { $_.path -eq 'main.exe' }).sha256)
