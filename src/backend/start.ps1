param([int]$Port = 38082, [string]$RunDirectory = '', [string]$Data = '', [string]$BuildRoot = '', [string]$Cors = 'http://127.0.0.1:5173,http://localhost:5173', [switch]$TestFaults, [string]$TestNow = '', [int]$ConfirmTtl = 300)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/pscompat.ps1')
Assert-PowerShell7
Set-Utf8Console
$backendWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$BuildRoot) {
    $latest = Join-Path $backendWorkspace 'temp/backend/latest-build.json'
    if (!(Test-Path -LiteralPath $latest)) { & (Join-Path $PSScriptRoot 'build.ps1'); if ($LASTEXITCODE) { throw 'Build failed' } }
    $BuildRoot = (Read-JsonFile $latest).buildRoot
}
$exe = Join-Path $BuildRoot 'backend/target/release/bin/main.exe'
if (!(Test-Path -LiteralPath $exe)) {
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $BuildRoot 'backend/target/release') -Recurse -Filter '*.exe' -File)
    if ($candidates.Count -ne 1) { throw 'Cannot resolve backend executable. Build first.' }
    $exe = $candidates[0].FullName
}
if (!$RunDirectory) { $RunDirectory = Join-Path $backendWorkspace ('temp/backend/runs/' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '_' + $PID) }
$RunDirectory = [IO.Path]::GetFullPath($RunDirectory)
$ownedRoot = [IO.Path]::GetFullPath((Join-Path $backendWorkspace 'temp/backend')) + [IO.Path]::DirectorySeparatorChar
if (!$RunDirectory.StartsWith($ownedRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'RunDirectory must stay in temp/backend.' }
New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
if (!$Data) { $Data = Join-Path $backendWorkspace 'src/data/synthetic.runtime.json' }
$Data = [IO.Path]::GetFullPath($Data)
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
try { $listener.Start() } catch { $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start() }
$Port = $listener.LocalEndpoint.Port
$listener.Stop()
. 'C:/Program Files (x86)/Cangjie/envsetup.ps1'
$env:Path = (Join-Path $BuildRoot 'stdx') + ';' + $env:Path
$processEnv = @{ICT_PORT="$Port";ICT_DATA=$Data;ICT_STORE=(Join-Path $RunDirectory 'store.json');ICT_CORS=$Cors;ICT_ENABLE_TEST_FAULTS=$(if ($TestFaults) {'1'} else {'0'});ICT_TEST_NOW=$TestNow;ICT_CONFIRM_TTL="$ConfirmTtl"}
# Start-Process -Environment is PowerShell 7.4+. On older hosts the child inherits the
# process environment, so set it temporarily and restore it afterwards.
$startArgs = @{FilePath=$exe;WorkingDirectory=$RunDirectory;WindowStyle='Hidden';PassThru=$true;RedirectStandardOutput=(Join-Path $RunDirectory 'stdout.log');RedirectStandardError=(Join-Path $RunDirectory 'stderr.log')}
$savedEnv = @{}
foreach ($key in @($processEnv.Keys)) { $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
try {
    foreach ($key in @($processEnv.Keys)) { [Environment]::SetEnvironmentVariable($key, [string]$processEnv[$key], 'Process') }
    if ($PSVersionTable.PSVersion -ge [version]'7.4') { $startArgs.Environment = $processEnv }
    $process = Start-Process @startArgs
} finally {
    foreach ($key in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
}
try {
    for ($attempt=0;$attempt -lt 40;$attempt++) {
        if ($process.HasExited) { throw ('Backend exited: ' + (Get-Content (Join-Path $RunDirectory 'stderr.log') -Raw)) }
        $healthArgs = @{Uri="http://127.0.0.1:$Port/health";TimeoutSec=1}
        if ($PSVersionTable.PSVersion.Major -ge 6) { $healthArgs.NoProxy = $true }
        try { $health=Invoke-RestMethod @healthArgs; break } catch { Start-Sleep -Milliseconds 150 }
    }
    if ($health.code -ne 'OK' -or !$health.data.synthetic) { throw 'Health check failed' }
} catch { if (!$process.HasExited) { Stop-Process -Id $process.Id }; throw }
$receipt = @{processId=$process.Id;url="http://127.0.0.1:$Port";port=$Port;runDirectory=$RunDirectory;exe=$exe;buildRoot=$BuildRoot;data=$Data;cors=$Cors;testFaults=[bool]$TestFaults;testNow=$TestNow;confirmTtl=$ConfirmTtl;startedAt=(Get-Date -Format o);health=$health}
$receipt['running'] = $true
Write-JsonFile (Join-Path $RunDirectory 'server.json') $receipt 8
Write-JsonFile (Join-Path $backendWorkspace 'temp/backend/latest-server.json') $receipt 8
$receipt | ConvertTo-Json -Depth 8
