param([switch]$SkipBuild, [string]$Data = '')
# Compatibility note: this file is intentionally ASCII-only so that Windows PowerShell 5.1,
# which decodes BOM-less scripts with the system code page, reads it correctly.
# Non-ASCII request payloads are written as JSON \u escapes for the same reason.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/pscompat.ps1')
Assert-PowerShell7
Set-Utf8Console
$shellExe = Get-HostShellPath
$shellLabel = Get-HostShellLabel
$verifyWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$verifyId = Get-Date -Format 'yyyyMMddTHHmmssfff'
$verifyAudit = Join-Path $verifyWorkspace ('audit/backend/' + $verifyId + '_verification')
$verifyRun = Join-Path $verifyWorkspace ('temp/backend/verification/' + $verifyId)
New-Item -ItemType Directory -Path $verifyAudit,$verifyRun -Force | Out-Null
$verifySteps = [Collections.Generic.List[object]]::new()
$servers = [Collections.Generic.List[object]]::new()
$verifyFailure = $null
if (!$Data) { $Data = Join-Path $verifyWorkspace 'src/data/synthetic.runtime.json' }
$fixedNow = ([DateTimeOffset](Read-JsonFile $Data).generatedAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
function Step([string]$Name,[string]$Command,[scriptblock]$Action) {
    $global:LASTEXITCODE=0
    $out=@(& $Action 2>&1 | ForEach-Object { "$_" })
    $code=$LASTEXITCODE
    Write-Utf8NoBom (Join-Path $verifyAudit ($Name+'.log')) ($out -join [Environment]::NewLine)
    $verifySteps.Add(@{name=$Name;command=$Command;exitCode=$code;output=$out})
    $out | ForEach-Object { Write-Host $_ }
    if ($code) { throw ($Name+' failed with exit code '+$code) }
}
function StopOwned($Server) {
    $process=Get-Process -Id $Server.processId -ErrorAction SilentlyContinue
    if ($process) {
        if ([IO.Path]::GetFullPath($process.Path) -ne [IO.Path]::GetFullPath($Server.exe)) { throw 'Owned process identity mismatch.' }
        Stop-Process -Id $Server.processId
        $process.WaitForExit()
    }
    $Server['stoppedAt'] = Get-Date -Format o
    $Server['processStopped'] = !(Get-Process -Id $Server.processId -ErrorAction SilentlyContinue)
}
try {
    if (!$SkipBuild) { Step 'backend_build_test' ($shellLabel + ' -NoProfile -File src/backend/build.ps1 -Test') { & $shellExe -NoProfile -File (Join-Path $PSScriptRoot 'build.ps1') -Test } }
    $latest=Read-JsonFile (Join-Path $verifyWorkspace 'temp/backend/latest-build.json')
    Step 'start_test_server' '& src/backend/start.ps1 -TestFaults -TestNow <dataset.generatedAt> -Data <dataset> -RunDirectory <unique>' { & (Join-Path $PSScriptRoot 'start.ps1') -Port 38083 -TestFaults -TestNow $fixedNow -Data $Data -RunDirectory $verifyRun -BuildRoot $latest.buildRoot }
    $server=ConvertTo-Hashtable (Read-JsonFile (Join-Path $verifyRun 'server.json'))
    $servers.Add($server)
    $env:ICT_BASE_URL=$server.url
    $env:ICT_TEST_OUTPUT=Join-Path $verifyAudit 'http.integration.json'
    Step 'http_integration' 'node src/backend/tests/http.integration.mjs' { & node (Join-Path $PSScriptRoot 'tests/http.integration.mjs') }
    $env:ICT_TEST_OUTPUT=Join-Path $verifyAudit 'retrieval.development.json'
    Step 'retrieval_development' 'node src/backend/tests/retrieval.development.mjs (20 queries x 3 rounds)' { & node (Join-Path $PSScriptRoot 'tests/retrieval.development.mjs') }
    Step 'retrieval_metrics_unit' 'node src/backend/tests/retrieval.metrics.test.mjs' { & node (Join-Path $PSScriptRoot 'tests/retrieval.metrics.test.mjs') }
    $env:ICT_TEST_OUTPUT=Join-Path $verifyAudit 'retrieval.empty-counterexample.json'
    Step 'retrieval_empty_counterexample' 'node src/backend/tests/retrieval.development.empty.test.mjs' { & node (Join-Path $PSScriptRoot 'tests/retrieval.development.empty.test.mjs') }
    $env:ICT_TEST_OUTPUT=Join-Path $verifyAudit 'retrieval.top5-counterexample.json'
    Step 'retrieval_top5_counterexample' 'node src/backend/tests/retrieval.development.top5.test.mjs' { $env:ICT_TOP5_TEST_OUTPUT=Join-Path $verifyAudit 'retrieval.top5-counterexample.json'; & node (Join-Path $PSScriptRoot 'tests/retrieval.development.top5.test.mjs') }
    $env:ICT_TEST_OUTPUT=Join-Path $verifyAudit 'retrieval.gateway-metadata-counterexample.json'
    Step 'retrieval_gateway_metadata_counterexamples' 'node src/backend/tests/retrieval.development.gateway-metadata.test.mjs' { & node (Join-Path $PSScriptRoot 'tests/retrieval.development.gateway-metadata.test.mjs') }
    $env:ICT_TEST_OUTPUT=Join-Path $verifyAudit 'retrieval.summary-fixtures.json'
    Step 'retrieval_gateway_summary_fixtures' 'node src/backend/tests/retrieval.development.summary.test.mjs (local HTTP fixtures only)' { & node (Join-Path $PSScriptRoot 'tests/retrieval.development.summary.test.mjs') }
    Write-JsonFile (Join-Path $verifyAudit 'first-server.json') $server 10
    StopOwned $server
    Step 'restart_persistent_server' '& src/backend/start.ps1 -TestFaults -TestNow <same clock> -Data <same dataset> -RunDirectory <same>' { & (Join-Path $PSScriptRoot 'start.ps1') -Port $server.port -TestFaults -TestNow $fixedNow -Data $Data -RunDirectory $verifyRun -BuildRoot $latest.buildRoot }
    $restarted=ConvertTo-Hashtable (Read-JsonFile (Join-Path $verifyRun 'server.json'))
    $servers.Add($restarted); $env:ICT_BASE_URL=$restarted.url
    $env:ICT_HTTP_REPORT=Join-Path $verifyAudit 'http.integration.json';$env:ICT_SERVER_REPORT=Join-Path $verifyAudit 'first-server.json';$env:ICT_TEST_OUTPUT=Join-Path $verifyAudit 'recovery.json'
    Step 'restart_recovery' 'node src/backend/tests/recovery.mjs' { & node (Join-Path $PSScriptRoot 'tests/recovery.mjs') }
    StopOwned $restarted
    $fixed=([DateTimeOffset]::Parse($fixedNow)).AddDays(31).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $expiredRun=Join-Path $verifyRun 'expired'
    Step 'start_expired_clock' ('& src/backend/start.ps1 -TestNow '+$fixed) { & (Join-Path $PSScriptRoot 'start.ps1') -Port 38083 -Data $Data -RunDirectory $expiredRun -BuildRoot $latest.buildRoot -TestNow $fixed }
    $expired=ConvertTo-Hashtable (Read-JsonFile (Join-Path $expiredRun 'server.json'));$servers.Add($expired)
    $expiredBody='{"requestId":"expired-clock","location":"\u516c\u5171\u533a\u57df","description":"\u5408\u6210\u6545\u969c","contactAlias":"SYN-CONTACT-K"}'
    $expiredResponse=Invoke-JsonPost -Url ($expired.url+'/api/v1/ticket-drafts') -Session 'campus-user' -Json $expiredBody
    $value=$expiredResponse.body|ConvertFrom-Json
    if ($expiredResponse.status -ne 409 -or $value.code -ne 'EVIDENCE_NOT_APPLICABLE') { throw ('Expired evidence unexpectedly allowed a draft. status='+$expiredResponse.status+' code='+$value.code) }
    $verifySteps.Add(@{name='expired_evidence_http';command='POST ticket-drafts under generatedAt+31days test clock';exitCode=0;httpStatus=$expiredResponse.status;body=$value})
    StopOwned $expired
    foreach($item in $servers) {
        $verifySteps.Add(@{name='process_cleanup';command=('Stop owned backend PID '+$item.processId);exitCode=0;processStopped=$item.processStopped;url=$item.url})
    }
    $state=Read-JsonFile (Join-Path $verifyRun 'store.json')
    Write-Utf8NoBom (Join-Path $verifyAudit 'synthetic-state.snapshot.json') (($state | ConvertTo-Json -Depth 20))
} catch { $verifyFailure=$_.Exception.Message }
finally {
    foreach($item in $servers) { if (!$item.processStopped) { StopOwned $item } }
}
$reproduce=((Get-Process -Id $PID).ProcessName + '.exe -NoProfile -File src/backend/verify.ps1')
$result=@{status=$(if ($verifyFailure) {'failed'} else {'passed'});runId=$verifyId;completedAt=(Get-Date -Format o);audit=$verifyAudit;buildSkipped=[bool]$SkipBuild;shell=$shellLabel;shellExe=$shellExe;psVersion=$PSVersionTable.PSVersion.ToString();steps=@($verifySteps);servers=@($servers);failure=$verifyFailure;synthetic=$true;realBusinessWrite=$false;realG1Ran=$false;claimBoundary=$(if ($SkipBuild) {'Local development only; compilation was NOT re-run (-SkipBuild), so the build evidence is the previous recorded batch'} else {'Local development only; not blind testing, real business, AI gain, device verification or public release'});reproduce=$reproduce}
Write-JsonFile (Join-Path $verifyAudit 'result.json') $result 20
$lines=@('# Backend Verification', '', ('Status: '+$result.status), '', ('Failure: '+$verifyFailure), '', ('Shell: '+$shellLabel), '', ('Build re-run: '+(-not [bool]$SkipBuild)), '', 'All data synthetic; realBusinessWrite=false; real G1 not run. This is development verification.', '', '| Step | Command | Exit |', '| --- | --- | --- |')
foreach($step in $verifySteps){$lines+=('| '+$step.name+' | `'+$step.command+'` | '+$step.exitCode+' |')}
$lines+=@('', 'Raw outputs and HTTP/retrieval/recovery evidence are in this directory. Only owned test processes were stopped. Original data and other chat services were not changed.', '', ('Reproduce: `'+$reproduce+'`'))
Write-Utf8NoBom (Join-Path $verifyAudit 'result.md') ($lines -join [Environment]::NewLine)
Write-Output ('Verification='+$result.status+' Audit='+$verifyAudit+' Shell='+$shellLabel+' Failure='+$verifyFailure)
if($verifyFailure){exit 1}
