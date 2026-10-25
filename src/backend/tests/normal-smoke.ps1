$ErrorActionPreference='Stop'
$smokeWorkspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$smokeServer=Get-Content (Join-Path $smokeWorkspace 'temp/backend/latest-server.json') -Raw | ConvertFrom-Json
$smokeId=Get-Date -Format 'yyyyMMddTHHmmssfff'
$smokeReport=Join-Path $smokeWorkspace ('audit/backend/'+$smokeId+'_normal_smoke.json')
$checks=@()
if($smokeServer.testFaults){throw 'Normal smoke requires test faults disabled'}
foreach($case in @(
    @{name='health';path='/health';method='GET';code='OK';status=200},
    @{name='notices';path='/api/v1/notices';method='GET';code='OK';status=200},
    @{name='signup_query';path='/api/v1/activity-signups';method='GET';code='OK';status=200},
    @{name='test_peer_disabled';path='/api/v1/activity-signups';method='GET';session='campus-test-peer';code='UNAUTHORIZED';status=401},
    @{name='chat_g0';path='/api/v1/chat';method='POST';body='{"requestId":"normal-g0","text":"报修"}';code='OK';status=200},
    @{name='mock_disabled';path='/api/v1/chat';method='POST';body='{"requestId":"normal-mock","text":"报修","mockFault":"timeout"}';code='VALIDATION_ERROR';status=400},
    @{name='debug_disabled';path='/api/v1/debug/streams';method='GET';session='campus-worker';code='FORBIDDEN';status=403}
)){
    $session=if($case.session){$case.session}else{'campus-user'}
    $parameters=@{Uri=($smokeServer.url+$case.path);Method=$case.method;Headers=@{'X-Demo-Session'=$session;'Origin'='http://127.0.0.1:5173'};NoProxy=$true;SkipHttpErrorCheck=$true;TimeoutSec=5}
    if($case.body){$parameters.Body=[Text.Encoding]::UTF8.GetBytes($case.body);$parameters.ContentType='application/json'}
    $response=Invoke-WebRequest @parameters
    $value=$response.Content|ConvertFrom-Json
    $passed=$response.StatusCode -eq $case.status -and $value.code -eq $case.code -and $value.data.synthetic -eq $true -and $value.data.realBusinessWrite -eq $false
    $checks+=@{name=$case.name;method=$case.method;path=$case.path;status=$response.StatusCode;code=$value.code;passed=$passed;response=$value}
}
$result=@{status=$(if(@($checks|Where-Object {!$_.passed}).Count){'failed'}else{'passed'});server=$smokeServer;checks=$checks;exitCode=0;completedAt=(Get-Date -Format o)}
$result | ConvertTo-Json -Depth 20 | Set-Content $smokeReport -Encoding utf8
@('# Normal Server Smoke', '', ('Status: '+$result.status), '', ('URL: '+$smokeServer.url), '', 'Health, notices, G0 and default-disabled Mock/debug boundary were executed. No business record was created.') | Set-Content ([IO.Path]::ChangeExtension($smokeReport,'.md')) -Encoding utf8
Write-Output ('NormalSmoke='+$result.status+' Report='+$smokeReport)
if($result.status -ne 'passed'){exit 1}
