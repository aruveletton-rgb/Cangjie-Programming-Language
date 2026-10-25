# Shared compatibility helpers.
# Goal: the same script runs on Windows PowerShell 5.1 and PowerShell 7+ without a pwsh dependency.
# Rules enforced here: UTF-8 without BOM on write, explicit UTF-8 on read, hashtable conversion
# that does not rely on ConvertFrom-Json -AsHashtable (PowerShell 7 only).

function Set-Utf8Console {
    try { [Console]::OutputEncoding = (New-Object Text.UTF8Encoding($false)) } catch { }
    try { $global:OutputEncoding = (New-Object Text.UTF8Encoding($false)) } catch { }
}

# Windows PowerShell 5.1 is not a supported host for this pipeline. Two measured reasons:
#   1. cjpm 1.0.5 exits with 0xC0000005 (access violation) when launched by powershell.exe 5.1.
#   2. Start-Process redirection fails on non-ASCII paths ("wildcard path" error), and the
#      workspace root D:\华为ICT is non-ASCII.
# Failing here turns a cryptic crash into an actionable message.
function Assert-PowerShell7 {
    if ($PSVersionTable.PSVersion.Major -ge 7) { return }
    throw ('PowerShell 7 or later is required (current: ' + $PSVersionTable.PSVersion.ToString() + '). ' +
        'cjpm 1.0.5 crashes with 0xC0000005 under Windows PowerShell 5.1, and Start-Process redirection fails on this non-ASCII workspace path. ' +
        'Run src\backend\verify.cmd, or invoke the bundled host: temp\tools\pwsh\pwsh.exe -NoProfile -File <script>.')
}

function Read-Utf8Text([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { throw ('File not found: ' + $Path) }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $dir = [IO.Path]::GetDirectoryName($Path)
    if ($dir -and !(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Read-JsonFile([string]$Path) {
    $text = (Read-Utf8Text $Path)
    if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return ($text | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Value, [int]$Depth = 10) {
    Write-Utf8NoBom $Path (($Value | ConvertTo-Json -Depth $Depth))
}

function ConvertTo-Hashtable($InputObject) {
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $map = @{}
        foreach ($key in @($InputObject.Keys)) { $map[$key] = ConvertTo-Hashtable $InputObject[$key] }
        return $map
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $map = @{}
        foreach ($property in $InputObject.PSObject.Properties) { $map[$property.Name] = ConvertTo-Hashtable $property.Value }
        return $map
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and !($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) { $list += ,(ConvertTo-Hashtable $item) }
        return $list
    }
    return $InputObject
}

# Current host executable, so child scripts are launched with the shell that is actually running.
function Get-HostShellPath {
    $exe = (Get-Process -Id $PID).Path
    if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return (Get-Command pwsh).Source }
    return (Join-Path $PSHOME 'powershell.exe')
}

function Get-HostShellLabel {
    return ((Get-Process -Id $PID).ProcessName + ' ' + $PSVersionTable.PSVersion.ToString())
}

# JSON POST that returns the status code instead of throwing on 4xx/5xx.
# PowerShell 7 has -SkipHttpErrorCheck; Windows PowerShell 5.1 does not, so it uses HttpWebRequest.
function Invoke-JsonPost([string]$Url, [string]$Session, [string]$Json, [int]$TimeoutSec = 30) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $response = Invoke-WebRequest -Uri $Url -Method POST -Headers @{ 'X-Demo-Session' = $Session } -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($Json)) -NoProxy -SkipHttpErrorCheck -TimeoutSec $TimeoutSec
        return [pscustomobject]@{ status = [int]$response.StatusCode; body = $response.Content }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method = 'POST'
    $request.ContentType = 'application/json'
    $request.ContentLength = $bytes.Length
    $request.Proxy = $null
    $request.Timeout = $TimeoutSec * 1000
    $stream = $request.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    try { $raw = $request.GetResponse() }
    catch [System.Net.WebException] {
        $raw = $_.Exception.Response
        if (!$raw) { throw }
    }
    $status = [int]$raw.StatusCode
    $reader = New-Object IO.StreamReader($raw.GetResponseStream(), [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close(); $raw.Close()
    return [pscustomobject]@{ status = $status; body = $body }
}
