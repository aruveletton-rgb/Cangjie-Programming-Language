$ErrorActionPreference = 'Stop'
$releaseWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$releaseRunId = Get-Date -Format 'yyyyMMddTHHmmssfff'
$releaseDirectory = Join-Path $releaseWorkspace ('artifacts/backend/' + $releaseRunId)
$releaseAudit = Join-Path $releaseWorkspace ('audit/backend/' + $releaseRunId + '_release')
$releaseTemp = Join-Path ([IO.Path]::GetTempPath()) ('ict_backend_release_' + $releaseRunId + '_' + $PID)
New-Item -ItemType Directory -Path $releaseDirectory,$releaseAudit,$releaseTemp -Force | Out-Null
$archive = Join-Path $releaseDirectory 'cj_zh_search-0.1.0-local-candidate.zip'
Compress-Archive -LiteralPath (Join-Path $releaseWorkspace 'src/cj_zh_search') -DestinationPath $archive
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Expand-Archive -LiteralPath $archive -DestinationPath $releaseTemp
. 'C:/Program Files (x86)/Cangjie/envsetup.ps1'
$steps = @()
foreach ($step in @(@{cwd='cj_zh_search';args=@('build')},@{cwd='cj_zh_search';args=@('test','--no-color')},@{cwd='cj_zh_search';args=@('bench','--no-color')},@{cwd='cj_zh_search/examples/consumer';args=@('run')})) {
    Push-Location (Join-Path $releaseTemp $step.cwd)
    try { $out = @(& cjpm @($step.args) 2>&1 | ForEach-Object ToString); $code=$LASTEXITCODE } finally { Pop-Location }
    $name = ($step.cwd.Replace('/','_')+'_'+$step.args[0])
    $out | Set-Content -LiteralPath (Join-Path $releaseAudit ($name+'.log')) -Encoding utf8
    $steps += @{command=('cjpm '+($step.args -join ' '));cwd=$step.cwd;exitCode=$code;output=$out}
    $out | ForEach-Object { Write-Host $_ }
    if ($code) { break }
    if ($step.args[0] -eq 'bench' -and ($out -join "`n") -notmatch 'query1000') { throw 'No actual benchmarks discovered.' }
    if ($step.args[0] -eq 'run' -and ($out -join "`n") -notmatch 'independent-consumer-ok') { throw 'Independent consumer result missing.' }
}
$result = @{status=$(if ($code) {'failed'} else {'passed'});archive=$archive;sha256=$hash;version='0.1.0';license='pending_rights_holder_confirmation';publiclyPublished=$false;extractedTo=$releaseTemp;steps=$steps;completedAt=(Get-Date -Format o);sdk=((& cjc --version)-join "`n");cpu=(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)}
$result | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $releaseAudit 'result.json') -Encoding utf8
$result | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $releaseDirectory 'manifest.json') -Encoding utf8
Write-Output ('Archive='+$archive+' SHA256='+$hash+' Audit='+$releaseAudit)
if ($code) { exit $code }
