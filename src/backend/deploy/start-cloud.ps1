param(
    [int]$Port = 38082,
    [int]$TlsPort = 8443,
    [string]$PublicOrigin = '',
    [string]$Cert = '',
    [string]$Key = '',
    [string]$NodeExe = 'node'
)
# Start the cloud bundle on a Windows host: backend on loopback, TLS proxy in front.
#
# Compatible with Windows PowerShell 5.1 (the default on Windows Server), so the cloud
# host does not need PowerShell 7 installed.
#
# Order matters: the backend binds 127.0.0.1 only (main.cj), so the proxy is the only
# external entry. Starting the proxy first yields UPSTREAM_UNAVAILABLE by design.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$exe = Join-Path $root 'main.exe'
$proxy = Join-Path $root 'deploy/tls-proxy.mjs'
if (!(Test-Path -LiteralPath $exe)) { throw ('main.exe missing: ' + $exe) }
if (!(Test-Path -LiteralPath $proxy)) { throw ('tls-proxy.mjs missing: ' + $proxy) }
if (!$Cert) { $Cert = Join-Path $root 'tls/tls.crt' }
if (!$Key) { $Key = Join-Path $root 'tls/tls.key' }
if (!(Test-Path -LiteralPath $Cert)) { throw ('certificate missing: ' + $Cert + ' (run deploy/gen-cert.sh first)') }
if (!(Test-Path -LiteralPath $Key)) { throw ('private key missing: ' + $Key) }

$env:Path = (Join-Path $root 'stdx') + ';' + $env:Path
$env:ICT_PORT = "$Port"
$env:ICT_DATA = Join-Path $root 'data/synthetic.runtime.json'
$env:ICT_STORE = Join-Path $root 'state/store.json'
$env:ICT_CORS = 'http://127.0.0.1:5173,http://localhost:5173'
$env:ICT_CONFIRM_TTL = '300'
$env:ICT_ENABLE_TEST_FAULTS = '0'
if ($PublicOrigin) { $env:ICT_PUBLIC_ORIGIN = $PublicOrigin } else { Remove-Item Env:ICT_PUBLIC_ORIGIN -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path (Join-Path $root 'state'), (Join-Path $root 'logs') -Force | Out-Null

# Windows environment blocks can carry both HTTP_PROXY and http_proxy. Start-Process then
# fails with "duplicate key" because it copies the block into a case-sensitive dictionary.
# Keep the upper-case spelling and drop the duplicate, so the launch does not depend on
# whether a proxy was configured on the host.
foreach ($name in @('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')) {
    if ([Environment]::GetEnvironmentVariable($name, 'Process')) {
        Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
    }
}

$backend = Start-Process -FilePath $exe -WorkingDirectory $root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $root 'logs/backend.stdout.log') `
    -RedirectStandardError (Join-Path $root 'logs/backend.stderr.log')

$health = $null
for ($i = 0; $i -lt 40; $i++) {
    if ($backend.HasExited) { throw ('backend exited early: ' + (Get-Content (Join-Path $root 'logs/backend.stderr.log') -Raw)) }
    try { $health = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/health") -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 250 }
}
if (!$health -or $health.code -ne 'OK') { Stop-Process -Id $backend.Id -Force; throw 'backend health check failed' }

$env:TLS_BIND = '0.0.0.0'
$env:TLS_PORT = "$TlsPort"
$env:TLS_CERT = $Cert
$env:TLS_KEY = $Key
$env:UPSTREAM = "http://127.0.0.1:$Port"
$env:TLS_LOG = Join-Path $root 'logs/tls-proxy.log'
$proxyProc = Start-Process -FilePath $NodeExe -ArgumentList @($proxy) -WorkingDirectory $root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $root 'logs/proxy.stdout.log') `
    -RedirectStandardError (Join-Path $root 'logs/proxy.stderr.log')

Start-Sleep -Seconds 2
$tlsOk = $false
$probeError = $null
try {
    # Prefer curl.exe: it is present on Windows Server 2019+ and its TLS stack does not
    # depend on ServicePointManager, which behaves differently across PowerShell versions.
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $probeBody = & $curl.Source -sk --noproxy '*' ("https://127.0.0.1:$TlsPort/health") -m 5
        $tlsOk = ("$probeBody" -match '"code"\s*:\s*"OK"')
        if (!$tlsOk) { $probeError = 'curl probe did not return code=OK' }
    } else {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $probe = Invoke-RestMethod -Uri ("https://127.0.0.1:$TlsPort/health") -TimeoutSec 5
        $tlsOk = ($probe.code -eq 'OK')
    }
} catch { $probeError = $_.Exception.Message } finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}

$receipt = @{
    startedAt    = (Get-Date -Format o)
    backendPid   = $backend.Id
    proxyPid     = $proxyProc.Id
    backendUrl   = "http://127.0.0.1:$Port"
    publicUrl    = "https://<public-ip>:$TlsPort"
    publicOrigin = $PublicOrigin
    tlsHealthOk  = $tlsOk
    tlsProbeError = $probeError
    certificate  = $Cert
    stateFile    = $env:ICT_STORE
    note         = 'Browsers warn about the self-signed certificate; that is expected for the IP entry.'
}
$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'state/server.json') -Encoding utf8
$receipt | ConvertTo-Json -Depth 4

if (!$tlsOk) { Write-Warning ('TLS health probe failed: ' + $probeError) }
