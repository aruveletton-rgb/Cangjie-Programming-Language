param([string]$BuildRoot = '')
$ErrorActionPreference = 'Stop'
$backendRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$BuildRoot) { $BuildRoot = Join-Path ([IO.Path]::GetTempPath()) ('ict_backend_' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '_' + $PID) }
if ($BuildRoot -match '[^\x00-\x7F]') { throw 'BuildRoot must be ASCII for cjpm 1.0.5.' }
$buildAudit = Join-Path $backendRoot ('audit/backend/' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '_library')
New-Item -ItemType Directory -Path $BuildRoot,$buildAudit -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $backendRoot 'src/cj_zh_search') -Destination (Join-Path $BuildRoot 'cj_zh_search') -Recurse
. 'C:/Program Files (x86)/Cangjie/envsetup.ps1'
$steps = @()
foreach ($step in @(@{cwd='cj_zh_search'; args=@('build')},@{cwd='cj_zh_search';args=@('test','--no-color')},@{cwd='cj_zh_search';args=@('bench','--no-color')},@{cwd='cj_zh_search/examples/consumer';args=@('run')})) {
    Push-Location (Join-Path $BuildRoot $step.cwd)
    try { $output = @(& cjpm @($step.args) 2>&1 | ForEach-Object ToString); $code = $LASTEXITCODE } finally { Pop-Location }
    $name = ($step.cwd.Replace('/','_') + '_' + $step.args[0])
    $output | Set-Content -LiteralPath (Join-Path $buildAudit ($name + '.log')) -Encoding utf8
    $steps += @{command='cjpm ' + ($step.args -join ' '); cwd=$step.cwd; exitCode=$code; output=$output}
    $output | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { break }
}
$result = @{buildRoot=$BuildRoot; audit=$buildAudit; steps=$steps; completedAt=(Get-Date -Format o)}
$result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $buildAudit 'result.json') -Encoding utf8
Write-Output ('BuildRoot=' + $BuildRoot + ' Audit=' + $buildAudit + ' exit=' + $code)
if ($code -ne 0) { exit $code }
