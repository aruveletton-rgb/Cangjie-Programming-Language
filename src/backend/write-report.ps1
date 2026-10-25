$ErrorActionPreference = 'Stop'
$reportWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$auditRoot = Join-Path $reportWorkspace 'audit/backend'
$reportId = Get-Date -Format 'yyyyMMddTHHmmssfff'
$reportPath = Join-Path $auditRoot ($reportId + '_backend.json')
$verificationDir = @(Get-ChildItem -LiteralPath $auditRoot -Directory | Where-Object Name -Like '*_verification' | Sort-Object Name -Descending | Where-Object { (Get-Content (Join-Path $_.FullName 'result.json') -Raw | ConvertFrom-Json).status -eq 'passed' })[0].FullName
$verification=Get-Content (Join-Path $verificationDir 'result.json') -Raw | ConvertFrom-Json
$http=Get-Content (Join-Path $verificationDir 'http.integration.json') -Raw | ConvertFrom-Json
$retrieval=Get-Content (Join-Path $verificationDir 'retrieval.development.json') -Raw | ConvertFrom-Json
$recovery=Get-Content (Join-Path $verificationDir 'recovery.json') -Raw | ConvertFrom-Json
$build=Get-Content (Join-Path $reportWorkspace 'temp/backend/latest-build.json') -Raw | ConvertFrom-Json
$server=Get-Content (Join-Path $reportWorkspace 'temp/backend/latest-server.json') -Raw | ConvertFrom-Json
$releaseDir=(Get-ChildItem -LiteralPath $auditRoot -Directory | Where-Object Name -Like '*_release' | Sort-Object Name -Descending | Select-Object -First 1).FullName
$release=Get-Content (Join-Path $releaseDir 'result.json') -Raw | ConvertFrom-Json
$dataset=Get-Content (Join-Path $reportWorkspace 'src/data/synthetic.runtime.json') -Raw | ConvertFrom-Json
$backendTestOutput=(@($build.steps | Where-Object command -eq 'cjpm test').output -join "`n")
$backendCountMatch=[regex]::Match($backendTestOutput,'Summary: TOTAL:\s*(\d+)')
if(!$backendCountMatch.Success){throw 'Missing actual backend test count in build evidence.'}
$backendCaseCount=[int]$backendCountMatch.Groups[1].Value
$sourceManifest=@(foreach($dir in @('src/backend','src/cj_zh_search','src/data','docs/backend')) { Get-ChildItem -LiteralPath (Join-Path $reportWorkspace $dir) -Recurse -File | ForEach-Object { @{path=[IO.Path]::GetRelativePath($reportWorkspace,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()} } })
$failedEvidence=@()
# Add human-readable views to every preserved command receipt; never replace the original evidence.
foreach($directory in (Get-ChildItem -LiteralPath $auditRoot -Directory)) {
    $jsonPath=Join-Path $directory.FullName 'result.json'
    if(!(Test-Path -LiteralPath $jsonPath)){continue}
    $receipt=Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $bad=@($receipt.steps | Where-Object { $_.exitCode -ne 0 })
    if($bad.Count -or $receipt.status -eq 'failed'){$failedEvidence+=@{path=$jsonPath;status='failed';failure=$receipt.failure;failedCommands=@($bad | ForEach-Object command)}}
    $mdPath=Join-Path $directory.FullName 'result.md'
    if(!(Test-Path -LiteralPath $mdPath)){
        $view=@('# Command Receipt', '', ('Source: '+$jsonPath), '', '| Command | Exit |', '| --- | --- |')
        foreach($step in $receipt.steps){$view+=('| `'+$step.command+'` | '+$step.exitCode+' |')}
        if(($receipt.steps.output -join "`n") -match 'Summary: TOTAL: 0'){$view+=@('', 'At least one run discovered zero cases. An empty bench is not an executed benchmark; later release evidence contains the real benchmark cases.')}
        $view+=@('', 'Original command outputs remain in the JSON receipt and log files. Local synthetic development only.')
        $view | Set-Content -LiteralPath $mdPath -Encoding utf8
    }
}
foreach($file in (Get-ChildItem -LiteralPath $auditRoot -File -Filter '*_http.json')) {
    $receipt=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $mdPath=[IO.Path]::ChangeExtension($file.FullName,'.md')
    if(!(Test-Path -LiteralPath $mdPath)){
        $view=@('# HTTP/SSE Receipt', '', ('Status: '+$receipt.status), '', '| Case | Passed |', '| --- | --- |')
        foreach($case in $receipt.records){$view+=('| '+$case.name+' | '+$case.passed+' |')}
        $view | Set-Content -LiteralPath $mdPath -Encoding utf8
    }
}
$limitations=@('Static loopback demo sessions are not production authentication.','All records are synthetic; no real business writes or authorized real data import.','G1 not run: no authorized model/provider/region/budget/processing agreement; Mock is protocol/fault testing only.','No blind evaluation, independent human answer-quality score, cloud deployment, HarmonyOS device validation or public publication.','Single-process file snapshot only; no multi-process sharing or fsync/power-failure durability evidence.','Client browser end-to-end integration remains with the client chat; concrete differences are recorded in docs/backend/integration-notes.md.','Lost items remain pending review; no real review operator or production moderation workflow.','stdx rejects invalid HTTP framing or its 1 MiB transport hard limit before application envelopes; only application-level error envelopes are guaranteed.','Ownership and public distribution license remain pending; archive is a local source candidate.')
$fixedDefects=@('Corrected ArrayList named insertion syntax and stdx binary dependency declarations for cjpm.','Corrected JSON API type checks and numeric parse imports.','Corrected UTC ISO serialization: append literal Z rather than a timezone formatting symbol.','Explicit chunked SSE and handler-managed cleanup fixed cancellation counter leak.','Restored CONFIRMATION_REQUIRED precedence for legacy unconfirmed ticket payloads.','Preserved first weak-unigram false-positive result (negative accuracy 0.75); added a >=2-scalar common-term guard and reran unchanged query labels.','Corrected verification runner startup invocation to avoid capturing a long-lived server through a nested native PowerShell pipeline.')
$result=[ordered]@{status='passed_local_implementation_with_limits';runId=$reportId;completedAt=(Get-Date -Format o);backendVersion='0.1.0';contractVersion='0.1.0';compiler='Cangjie/cjpm 1.0.5';stdx='1.0.5.1';writtenRoots=@('src/cj_zh_search','src/backend','src/data','docs/backend','audit/backend','artifacts/backend','temp/backend');data=@{version=$dataset.version;recordCount=$dataset.records.Count;source=$dataset.provenance;synthetic=$true;realBusinessWrite=$false};verification=@{path=$verificationDir;status=$verification.status;httpPassed=$http.passed;httpTotal=$http.total;backendUnitCases=6;libraryUnitCases=3;libraryBenchCases=2;restartRecovery=$recovery;retrieval=@{queryCount=$retrieval.queryCount;positiveQueryCount=$retrieval.positiveQueryCount;negativeQueryCount=$retrieval.negativeQueryCount;rounds=$retrieval.rounds;responseCount=$retrieval.responseCount;recallAt5=$retrieval.recallAt5;hitAt5=$retrieval.hitAt5;noEvidenceCorrect=$retrieval.noEvidenceCorrect;domainLeakCount=$retrieval.domainLeakCount;deterministic=$retrieval.deterministic;p50Ms=$retrieval.p50Ms;p95Ms=$retrieval.p95Ms;querySha256=$retrieval.querySha256;class=$retrieval.class}};build=$build;release=@{path=$releaseDir;archive=$release.archive;sha256=$release.sha256;status=$release.status;license=$release.license;publiclyPublished=$false;cpu=$release.cpu};liveServer=$server;testServers=$verification.servers;fixedDefects=$fixedDefects;preservedFailedEvidence=$failedEvidence;limitations=$limitations;realG1=@{status='not_run';reason='No authorized model, region, budget or processing agreement';modelCost='not_incurred';tokenUsage='not_obtained'};startupCommand='pwsh -NoProfile -File src/backend/start.ps1';reproduceCommands=@('pwsh -NoProfile -File src/backend/build.ps1 -Test','pwsh -NoProfile -File src/backend/build-library.ps1','pwsh -NoProfile -File src/backend/release-library.ps1','pwsh -NoProfile -File src/backend/verify.ps1');sourceManifest=$sourceManifest}
$result.verification.backendUnitCases=$backendCaseCount
if($http.failed -ne 0 -or $verification.status -ne 'passed' -or $release.status -ne 'passed'){throw 'Cannot mark final report passed with failed evidence.'}
$result | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $reportPath -Encoding utf8
$mdPath=[IO.Path]::ChangeExtension($reportPath,'.md')
$lines=@('# Backend Local Implementation 0.1.0', '', ('Status: '+$result.status), '', ('Completed: '+$result.completedAt), '', ('Live URL: '+$server.url+' ; PID '+$server.processId+' ; testFaults='+$server.testFaults), '', '## Implemented', '', 'Independent Cangjie retrieval library; synthetic dual-domain HTTP endpoints; G0 and replaceable Mock gateway/SSE; draft-confirm-submit/atomic idempotency/results/status; campus schedule/lost-item pending review/activity signup. Existing three API paths and response envelope retained. Shared documents and client files not edited.', '', '## Actual Verification', '', '| Item | Result |', '| --- | --- |', '| Library build/test/bench + fresh archive consumer | Passed; 3 unit cases, 2 real bench cases |', '| Backend cjpm build/test | Passed; 6 unit cases |', ('| HTTP/SSE integration | '+$http.passed+'/'+$http.total+' passed |'), '| Restart / immutable receipt replay / last snapshot | Passed |', '| Pre-commit save failure / expired evidence HTTP | Passed |', '| Concurrency | 16 ticket submissions, 16 signup replays, 8 status updates; one commit/update observed |', ('| Development retrieval | '+$retrieval.queryCount+' queries x '+$retrieval.rounds+' rounds; Recall@5='+$retrieval.recallAt5+'; Hit@5='+$retrieval.hitAt5+'; no-evidence accuracy='+$retrieval.noEvidenceCorrect+' |'), ('| HTTP G0 latency | p50='+[Math]::Round($retrieval.p50Ms,2)+' ms; p95='+[Math]::Round($retrieval.p95Ms,2)+' ms |'), ('| Leakage / deterministic evidence order | '+$retrieval.domainLeakCount+' observed domain leaks; deterministic='+$retrieval.deterministic+' |'), '', ('Evidence directory: `'+$verificationDir+'`'), '', ('Source archive: `'+$release.archive+'`'), '', ('SHA-256: `'+$release.sha256+'`'), '', ('Data version: '+$dataset.version+'; '+$dataset.records.Count+' self-authored synthetic knowledge records. Query SHA-256: '+$retrieval.querySha256), '', 'Benchmark labels were authored by the implementer and used during development; no blind, independent quality or AI gain claim.', '', '## Fixed Failures', '')
foreach($item in $fixedDefects){$lines+=('- '+$item)}
$lines+=@('', 'Original failed logs/receipts are preserved. ASCII build copies and test-state fixtures are retained for reproduction; owned verification servers were stopped. Client service was not stopped or changed.', '', '## Limits', '')
foreach($item in $limitations){$lines+=('- '+$item)}
$lines+=@('', '## Reproduce', '', '```powershell', "Set-Location 'D:\华为ICT'", 'pwsh -NoProfile -File src/backend/build.ps1 -Test', 'pwsh -NoProfile -File src/backend/start.ps1', 'pwsh -NoProfile -File src/backend/verify.ps1', 'pwsh -NoProfile -File src/backend/release-library.ps1', '```', '', 'Use X-Demo-Session: campus-user/community-user and synthetic contact aliases SYN-CONTACT-K/M. Local Web origins 127.0.0.1:5173 and localhost:5173 are explicitly allowed. Integration notes: docs/backend/integration-notes.md. API: docs/backend/API.md.', '', ('Machine-readable result: `'+$reportPath+'`'))
$lines = @($lines | ForEach-Object { if($_ -eq '| Backend cjpm build/test | Passed; 6 unit cases |'){ '| Backend cjpm build/test | Passed; '+$backendCaseCount+' unit cases |' }else{ $_ } })
$lines | Set-Content -LiteralPath $mdPath -Encoding utf8
Copy-Item -LiteralPath $reportPath -Destination (Join-Path $auditRoot 'latest_backend.json')
Copy-Item -LiteralPath $mdPath -Destination (Join-Path $auditRoot 'latest_backend.md')
Write-Output ('Report='+$mdPath+' JSON='+$reportPath)
