param([int]$BackendPort = 38082, [int]$WebPort = 5174, [string]$Data = '', [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$stamp = Get-Date -Format 'yyyyMMddTHHmmssfff'
$run = Join-Path $workspace "temp/integration/demo_$stamp"
New-Item -ItemType Directory -Path $run -Force | Out-Null
if (!$Data) {
    $Data = Join-Path $workspace "src/data/synthetic.demo.$stamp.json"
    & (Join-Path $PSScriptRoot 'generate-data.ps1') -Output $Data
}
if (!$SkipBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Test
    if ($LASTEXITCODE) { throw 'Backend build failed' }
}
& (Join-Path $PSScriptRoot 'start.ps1') -Port $BackendPort -Data $Data -RunDirectory (Join-Path $workspace "temp/backend/demo_$stamp") | Set-Content "$run/backend-start.log" -Encoding utf8
$backend = Get-Content (Join-Path $workspace 'temp/backend/latest-server.json') -Raw | ConvertFrom-Json
try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$WebPort)
    try { $listener.Start() } catch { $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start() }
    $WebPort = $listener.LocalEndpoint.Port; $listener.Stop()
    $webRoot = Join-Path $workspace 'src/web-demo'
    if (!(Test-Path -LiteralPath "$webRoot/node_modules/vite/bin/vite.js")) { throw 'Run npm ci in src/web-demo first' }
    $web = Start-Process -FilePath (Get-Command node.exe).Source -ArgumentList @('node_modules/vite/bin/vite.js','--host','127.0.0.1','--port',"$WebPort",'--strictPort') -WorkingDirectory $webRoot -Environment @{ICT_BACKEND_URL=$backend.url} -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run/web-stdout.log" -RedirectStandardError "$run/web-stderr.log"
    $url = "http://127.0.0.1:$WebPort"
    $ready = $false
    for ($i=0;$i -lt 40;$i++) {
        if ($web.HasExited) { throw 'Web process exited' }
        try { $response=Invoke-RestMethod "$url/backend/health" -NoProxy -TimeoutSec 2; if ($response.code -eq 'OK') { $ready=$true;break } } catch { Start-Sleep -Milliseconds 150 }
    }
    if (!$ready) { throw 'Web proxy health failed' }
    $receipt=@{startedAt=(Get-Date -Format o);backend=$backend;web=@{processId=$web.Id;exe=$web.Path;url=$url;port=$WebPort;proxyTarget=$backend.url};data=$Data;mode='actual clock; faults disabled; synthetic G0';runDirectory=$run}
    $receipt | ConvertTo-Json -Depth 15 | Set-Content "$run/demo.json" -Encoding utf8
    $receipt | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $workspace 'temp/integration/latest-demo.json') -Encoding utf8
    $receipt | ConvertTo-Json -Depth 15
} catch {
    if ($web -and !$web.HasExited) { Stop-Process -Id $web.Id }
    & (Join-Path $PSScriptRoot 'stop.ps1') -ServerRecord (Join-Path $backend.runDirectory 'server.json')
    throw
}
